<?php

namespace Darkone\NixGenerator;

class NixService
{
    // Voir comment automatiser, aller chercher dans la conf nix...
    // TODO: Trouver un moyen moins contraignant de faire ça, construire la liste des hosts dans dnsmasq
    //       et récupérer ces informations dans la conf nix.
    public const array UNIQUE_SERVICES_BY_ZONE = ['ncps', 'adguardhome', 'homepage'];
    public const array REVERSE_PROXY_SERVICES = [
        'adguardhome', 'auth', 'forgejo', 'home-assistant', 'homepage', 'immich', 'matrix', 'mattermost', 'monitoring',
        'netdata', 'nextcloud', 'syncthing', 'users', 'vaultwarden', 'keycloak', 'jitsi-meet', 'navidrome'
    ];

    // Doit être contacté avec son adresse ip fixe externe !
    public const array EXTERNAL_ACCESS_SERVICES = ['headscale'];

    private string $name;
    private string $host;
    private string $zone;
    private ?string $domain = null;
    private ?string $title = null;
    private ?string $description = null;
    private ?string $icon = null;
    private bool $global = false;

    public function getName(): string
    {
        return $this->name;
    }

    /**
     * @param string $name
     * @return $this
     */
    public function setName(string $name): NixService
    {
        $this->name = $name;
        return $this;
    }

    public function getHost(): string
    {
        return $this->host;
    }

    public function setHost(string $host): NixService
    {
        $this->host = $host;
        return $this;
    }

    public function getZone(): string
    {
        return $this->zone;
    }

    public function setZone(string $zone): NixService
    {
        $this->zone = $zone;
        return $this;
    }

    public function getDomain(): ?string
    {
        return $this->domain;
    }

    public function getFqdn(NixNetwork $network): string
    {
        $domain = $this->domain ?? $this->name;
        return $this->isGlobal()
            ? $domain . '.' . $network->getDomain()
            : $domain . '.' . $network->getZones()[$this->zone]->getDomain();
    }

    public function setDomain(?string $domain): NixService
    {
        is_null($domain) || $this->domain = $domain;
        return $this;
    }

    public function getTitle(): ?string
    {
        return $this->title;
    }

    public function setTitle(?string $title): NixService
    {
        is_null($title) || $this->title = $title;
        return $this;
    }

    public function getDescription(): ?string
    {
        return $this->description;
    }

    public function setDescription(?string $description): NixService
    {
        is_null($description) || $this->description = $description;
        return $this;
    }

    public function getIcon(): ?string
    {
        return $this->icon;
    }

    public function setIcon(?string $icon): NixService
    {
        is_null($icon) || $this->icon = $icon;
        return $this;
    }

    public function isGlobal(): bool
    {
        return $this->global;
    }

    public function setGlobal(bool $global): NixService
    {
        $this->global = $global;
        return $this;
    }

    public function toArray(): array
    {
        return array_filter([
            'name' => $this->getName(),
            'domain' => $this->getDomain(),
            'host' => $this->getHost(),
            'zone' => $this->getZone(),
            'title' => $this->getTitle(),
            'description' => $this->getDescription(),
            'icon' => $this->getIcon(),
            'global' => $this->isGlobal(),
        ]);
    }
}