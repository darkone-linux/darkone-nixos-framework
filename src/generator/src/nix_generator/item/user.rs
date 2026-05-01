use std::path::Path;

use crate::error::{NixError, Result};

const PROFILE_PATHS: &[&str] = &["usr/home/profiles/{}", "dnf/home/profiles/{}"];

#[derive(Debug)]
pub struct User {
    pub login: String,
    pub uid: u32,
    pub name: String,
    pub email: Option<String>,
    pub profile: String,
    pub groups: Vec<String>,
}

#[derive(Debug)]
pub struct UserBuildConfig<'a> {
    pub login: &'a str,
    pub uid: u32,
    pub name: &'a str,
    pub email: Option<&'a str>,
    pub profile: &'a str,
    pub groups: Vec<String>,
    pub uid_tracker: &'a mut std::collections::HashMap<u32, String>,
    pub project_root: &'a Path,
}

impl User {
    pub fn build(config: UserBuildConfig<'_>) -> Result<Self> {
        let UserBuildConfig {
            login,
            uid,
            name,
            email,
            profile,
            groups,
            uid_tracker,
            project_root,
        } = config;

        if !(1000..=64999).contains(&uid) {
            return Err(NixError::validation(format!(
                "UID '{uid}' out of bound, must be between 1000 and 64999"
            )));
        }
        if let Some(existing) = uid_tracker.get(&uid) {
            return Err(NixError::validation(format!(
                "Duplicated uid \"{uid}\" for {login} and {existing}"
            )));
        }
        if uid_tracker.values().any(|v| v == login) {
            return Err(NixError::validation(format!(
                "Duplicated login \"{login}\""
            )));
        }
        uid_tracker.insert(uid, login.to_string());

        let profile = filter_profile(profile, project_root)?;

        Ok(Self {
            login: login.to_string(),
            uid,
            name: name.to_string(),
            email: email.filter(|e| !e.is_empty()).map(str::to_string),
            profile,
            groups,
        })
    }
}

pub fn filter_profile(profile: &str, project_root: &Path) -> Result<String> {
    for template in PROFILE_PATHS {
        let relative = template.replace("{}", profile);
        if project_root.join(&relative).exists() {
            return Ok(relative);
        }
    }
    Err(NixError::validation(format!(
        "No user profile path found for profile \"{profile}\" in usr and dnf declarations."
    )))
}

impl User {
    /// Like filter_profile but returns Ok even when not found (for the special nix user).
    pub fn filter_profile_unchecked(profile: &str, project_root: &Path) -> Result<String> {
        filter_profile(profile, project_root)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::fs;
    use tempfile::tempdir;

    fn make_user(
        login: &str,
        uid: u32,
        tracker: &mut HashMap<u32, String>,
        root: &Path,
    ) -> Result<User> {
        fs::create_dir_all(root.join("dnf/home/profiles/minimal")).unwrap();
        User::build(UserBuildConfig {
            login,
            uid,
            name: "Test User",
            email: None,
            profile: "minimal",
            groups: vec![],
            uid_tracker: tracker,
            project_root: root,
        })
    }

    #[test]
    fn valid_user() {
        let dir = tempdir().unwrap();
        let mut tracker = HashMap::new();
        assert!(make_user("alice", 1001, &mut tracker, dir.path()).is_ok());
    }

    #[test]
    fn uid_out_of_range() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("dnf/home/profiles/minimal")).unwrap();
        let mut tracker = HashMap::new();
        let err = User::build(UserBuildConfig {
            login: "bob",
            uid: 999,
            name: "Bob",
            email: None,
            profile: "minimal",
            groups: vec![],
            uid_tracker: &mut tracker,
            project_root: dir.path(),
        });
        assert!(err.is_err());
    }

    #[test]
    fn duplicate_uid() {
        let dir = tempdir().unwrap();
        let mut tracker = HashMap::new();
        make_user("alice", 1001, &mut tracker, dir.path()).unwrap();
        let err = make_user("bob", 1001, &mut tracker, dir.path());
        assert!(err.is_err());
    }

    #[test]
    fn duplicate_login() {
        let dir = tempdir().unwrap();
        let mut tracker = HashMap::new();
        make_user("alice", 1001, &mut tracker, dir.path()).unwrap();
        let err = make_user("alice", 1002, &mut tracker, dir.path());
        assert!(err.is_err());
    }

    #[test]
    fn profile_not_found() {
        let dir = tempdir().unwrap();
        let err = filter_profile("nonexistent", dir.path());
        assert!(err.is_err());
    }

    #[test]
    fn profile_found_in_dnf() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("dnf/home/profiles/admin")).unwrap();
        let result = filter_profile("admin", dir.path()).unwrap();
        assert_eq!(result, "dnf/home/profiles/admin");
    }

    #[test]
    fn profile_usr_takes_priority() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("usr/home/profiles/custom")).unwrap();
        fs::create_dir_all(dir.path().join("dnf/home/profiles/custom")).unwrap();
        let result = filter_profile("custom", dir.path()).unwrap();
        assert_eq!(result, "usr/home/profiles/custom");
    }
}
