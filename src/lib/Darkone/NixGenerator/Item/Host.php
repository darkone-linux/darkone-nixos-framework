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
     * Activated services
     */
    private array $services = [];

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

    /**
     * @throws NixException
     */
    public function registerServices(NixNetwork $extraNetwork, array $services): Host
    {
        Configuration::assert(
            Configuration::TYPE_ARRAY, $services, $this->getHostname() . '.services must contains collection of strings', null, Configuration::TYPE_ARRAY, true
        );
        foreach ($services as $name => $params) {
            $extraNetwork->registerAliases($this->getHostname(), [$this->populateService($name, $params)]);
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

    /**
     * @throws NixException
     * @return string alias name
     */
    public function populateService(string $name, ?array $params): string
    {
        $params = $params ?? [];
        isset($params['title']) && Configuration::assert(Configuration::TYPE_STRING, $params['title'], $this->getHostname() . '.services.' . $name . '.title must be a string');
        isset($params['description']) && Configuration::assert(Configuration::TYPE_STRING, $params['description'], $this->getHostname() . '.services.' . $name . '.description must be a string');
        isset($params['domain']) && Configuration::assert(Configuration::TYPE_STRING, $params['domain'], 'Invalid name: ' . $this->getHostname() . '.services.' . $name . '.domain', Configuration::REGEX_HOSTNAME);
        isset($params['icon']) && Configuration::assert(Configuration::TYPE_STRING, $params['icon'], 'Invalid name: ' . $this->getHostname() . '.services.' . $name . '.domain', Configuration::REGEX_HOSTNAME);
        $domain = $params['domain'] ?? $name;
        if (isset($this->services[$name])) {
            throw new NixException('Service ' . $this->getHostname() . ':' . $name . ' already registered');
        }
        $this->services[$name] = $params;
        unset($params['title'], $params['description'], $params['domain'], $params['icon']);
        if (!empty($params)) {
            throw new NixException('Service ' . $this->getHostname() . ':' . $name . ', unknown values ' . json_encode($params));
        }

        return $domain;
    }

    public function getServices(): array
    {
        return $this->services;
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
