<?php

namespace Darkone\NixGenerator\Item;

use Darkone\NixGenerator\Configuration;
use Darkone\NixGenerator\NixException;

class Host
{
    private string $hostname;
    private string $name;
    private string $profile;
    private bool $local = false;

    /**
     * @var array of string (logins)
     */
    private array $users = [];

    /**
     * Host groups (for link with users)
     */
    private array $groups = [];

    /**
     * Networks
     */
    private array $networks = [];

    /**
     * Host tags (for colmena deployments)
     */
    private array $tags = [];

    public function getHostname(): string
    {
        return $this->hostname;
    }

    public function setHostname(string $hostname): Host
    {
        $this->hostname = $hostname;
        return $this;
    }

    public function getName(): string
    {
        return $this->name;
    }

    public function setName(string $name): Host
    {
        $this->name = $name;
        return $this;
    }

    public function getUsers(): array
    {
        return $this->users;
    }

    public function setUsers(array $users): Host
    {
        array_map(fn ($key) => preg_match(
            Configuration::REGEX_LOGIN, $key) || throw new NixException("Bad login '$key'"),
            $users
        );
        $this->users = $users;
        return $this;
    }

    public function getGroups(): array
    {
        return $this->groups;
    }

    public function setGroups(array $groups): Host
    {
        $this->groups = $groups;
        return $this;
    }

    public function setNetworks(array $networks): Host
    {
        $this->networks = $networks;
        return $this;
    }

    public function getNetworks(): array
    {
        return $this->networks;
    }

    public function setProfile(string $profile): Host
    {
        $this->profile = $profile;
        return $this;
    }

    public function getProfile(): string
    {
        return $this->profile;
    }

    public function setTags(array $tags): Host
    {
        // TODO: array_map(fn (string $tag): if ($tag), $tags);
        $this->tags = $tags;
        return $this;
    }

    public function getTags(): array
    {
        return $this->tags;
    }

    public function setLocal(bool $local): Host
    {
        $this->local = $local;
        return $this;
    }

    public function isLocal(): bool
    {
        return $this->local;
    }
}