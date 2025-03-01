<?php

namespace Darkone\NixGenerator\Item;

use Darkone\NixGenerator\Configuration;
use Darkone\NixGenerator\NixException;
use Darkone\NixGenerator\NixNetwork;

class Host
{
    private string $hostname;
    private string $name;
    private string $profile;
    private bool $local = false;
    private ?string $ip;
    private ?string $arch;

    /**
     * @var array of string (logins)
     */
    private array $users = [];

    /**
     * Host groups (for link with users)
     */
    private array $groups = [];

    /**
     * Host tags (for colmena deployments)
     */
    private array $tags = [];

    /**
     * @throws NixException
     */
    public function registerAliases(NixNetwork $extraNetwork, array $aliases): Host
    {
        $extraNetwork->registerAliases($this->getHostname(), $aliases);
        return $this;
    }

    /**
     * @throws NixException
     */
    public function registerInterfaces(NixNetwork $extraNetwork, array $interfaces): Host
    {
        $extraNetwork->registerHost($this->getHostname(), $interfaces[0]['ip'] ?? null);
        foreach ($interfaces as $interface) {
            $extraNetwork->registerMacAddress($interface['mac'], $interface['ip'], $this->getHostname());
        }
        return $this;
    }

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

    public function getIp(): ?string
    {
        return $this->ip;
    }

    public function setIp(?string $ip): Host
    {
        $this->ip = $ip;
        return $this;
    }

    public function getArch(): ?string
    {
        return $this->arch;
    }

    public function setArch(?string $arch): Host
    {
        $this->arch = $arch;
        return $this;
    }
}
