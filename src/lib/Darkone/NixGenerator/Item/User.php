<?php

namespace Darkone\NixGenerator\Item;

use Darkone\NixGenerator\NixException;

class User
{
    private static array $uids = [];

    private const PROFILE_PATHS = ["usr/homes/%s", "dnf/homes/%s"];

    private string $login;
    private int $uid;
    private string $name;
    private ?string $email = null;
    private string $profile;
    private array $groups = [];

    /**
     * @throws NixException
     * @todo manage the special nix user
     */
    public function setUidAndLogin(int $uid, string $login): User
    {
        ($uid < 1000 || $uid >= 65001) &&
            throw new NixException(
                "UID '$uid' out of bound, must be between 1000 and 64999"
            );
        isset(self::$uids[$uid]) &&
            throw new NixException(
                'Duplicated uid "' .
                    $uid .
                    '" for ' .
                    $login .
                    " and " .
                    self::$uids[$uid]
            );
        in_array($login, self::$uids) &&
            throw new NixException('Duplicated login "' . $login . '"');
        self::$uids[$uid] = $login;
        $this->login = $login;
        $this->uid = $uid;
        return $this;
    }

    public function setName(string $name): User
    {
        $this->name = $name;
        return $this;
    }

    public function setEmail(?string $email): User
    {
        is_null($email) || ($this->email = $email);
        return $this;
    }

    /**
     * @throws NixException
     */
    public function setProfile(string $profile): User
    {
        $this->profile = $this->filterProfile($profile);
        return $this;
    }

    /**
     * @throws NixException
     */
    public function filterProfile(string $profile): string
    {
        static $validProfiles = [];

        $found = false;
        foreach (self::PROFILE_PATHS as $path) {
            $profilePath = sprintf($path, $profile);
            if (in_array($profilePath, $validProfiles)) {
                $found = true;
                break;
            }
            if (file_exists(NIX_PROJECT_ROOT . "/" . $profilePath)) {
                $validProfiles[] = $profilePath;
                $found = true;
                break;
            }
        }
        $found ||
            throw new NixException(
                'No user profile path found for profile "' .
                    $profile .
                    '" in usr and dnf declarations.'
            );
        isset($profilePath) ||
            throw new NixException("Profile path is not set");

        return $profilePath;
    }

    public function setGroups(array $groups): User
    {
        $this->groups = $groups;
        return $this;
    }

    public function getLogin(): string
    {
        return $this->login;
    }

    public function getUid(): int
    {
        return $this->uid;
    }

    public function getName(): string
    {
        return $this->name;
    }

    public function getEmail(): ?string
    {
        return $this->email;
    }

    public function getProfile(): string
    {
        return $this->profile;
    }

    public function getGroups(): array
    {
        return $this->groups;
    }

    public function hasGroup(string $groupName): bool
    {
        return in_array($groupName, $this->groups);
    }
}
