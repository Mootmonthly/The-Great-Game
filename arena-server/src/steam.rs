//! Steam sign-in: the client sends a session ticket from
//! `ISteamUser::GetAuthTicketForWebApi`, and the server asks Steam who it
//! belongs to (ISteamUserAuth/AuthenticateUserTicket). Needs the game's
//! Steam App ID and a publisher Web API key.

use std::time::Duration;

#[derive(Clone, Debug)]
pub struct SteamConfig {
    pub app_id: u32,
    pub web_api_key: String,
    /// The identity string the client passed to GetAuthTicketForWebApi.
    pub identity: String,
}

/// Returns the SteamID64 that owns `ticket`.
pub fn authenticate(cfg: &SteamConfig, ticket: &str) -> Result<String, String> {
    if ticket.is_empty() || ticket.len() > 4096 || !ticket.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("malformed Steam ticket".into());
    }
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(10))
        .build();
    let response: serde_json::Value = agent
        .get("https://partner.steam-api.com/ISteamUserAuth/AuthenticateUserTicket/v1/")
        .query("key", &cfg.web_api_key)
        .query("appid", &cfg.app_id.to_string())
        .query("ticket", ticket)
        .query("identity", &cfg.identity)
        .call()
        .map_err(|e| format!("could not reach Steam: {e}"))?
        .into_json()
        .map_err(|e| format!("bad reply from Steam: {e}"))?;
    parse(&response)
}

fn parse(response: &serde_json::Value) -> Result<String, String> {
    let r = &response["response"];
    if let Some(desc) = r["error"]["errordesc"].as_str() {
        return Err(format!("Steam refused the ticket: {desc}"));
    }
    let p = &r["params"];
    if p["result"].as_str() != Some("OK") {
        return Err("Steam did not accept the ticket".into());
    }
    if p["vacbanned"].as_bool() == Some(true) || p["publisherbanned"].as_bool() == Some(true) {
        return Err("this Steam account is banned".into());
    }
    let id = p["steamid"].as_str().ok_or("Steam sent no SteamID")?;
    if id.is_empty() || id.len() > 17 || !id.bytes().all(|b| b.is_ascii_digit()) {
        return Err("Steam sent a malformed SteamID".into());
    }
    Ok(id.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_steam_replies() {
        let ok = json!({"response": {"params": {"result": "OK", "steamid": "76561197960287930",
            "ownersteamid": "76561197960287930", "vacbanned": false, "publisherbanned": false}}});
        assert_eq!(parse(&ok).unwrap(), "76561197960287930");
        let banned = json!({"response": {"params": {"result": "OK", "steamid": "1", "vacbanned": true}}});
        assert!(parse(&banned).is_err());
        let err = json!({"response": {"error": {"errorcode": 101, "errordesc": "Invalid ticket"}}});
        assert!(parse(&err).unwrap_err().contains("Invalid ticket"));
    }
}
