<?php

namespace Darkone\NixGenerator;

/**
 * @todo integrity tests + unit tests
 */
class NixNetwork
{
    private const string DEFAULT_DOMAIN = 'darkone.lan';

    private array $config;
    private array $zones = [];

    /**
     * @return NixZone[]
     */
    public function getZones(): array
    {
        return $this->zones;
    }

    /**
     * @param string $zoneName
     * @return NixZone
     * @throws NixException
     */
    public function getZone(string $zoneName): NixZone
    {
        if (!isset($this->getZones()[$zoneName])) {
            throw new NixException('Undefined zone "' . $zoneName . '"');
        }
        return $this->getZones()[$zoneName];
    }

    public function addZone(NixZone $zone): NixNetwork
    {
        $this->zones[$zone->getName()] = $zone;
        return $this;
    }

    public function getConfig(): array
    {
        return $this->config;
    }

    public function getDomain(): string
    {
        return $this->getConfig()['domain'];
    }

    public function getDefaultLocale(): ?string
    {
        return $this->getConfig()['default']['locale'] ?? null;
    }

    public function getDefaultTimezone(): ?string
    {
        return $this->getConfig()['default']['timezone'] ?? null;
    }

    // TODO: detect unknown keys

    /**
     * @param array $config
     * @return $this
     * @throws NixException
     */
    public function registerNetworkConfig(array $config): NixNetwork
    {
        $config['domain'] ??= self::DEFAULT_DOMAIN;
        Configuration::assert(Configuration::TYPE_STRING, $config['domain'], 'Bad network domain type');
        Configuration::assert(Configuration::TYPE_STRING, $config['default']['locale'] ?? '', 'Bad default network locale syntax', Configuration::REGEX_LOCALE);
        Configuration::assert(Configuration::TYPE_STRING, $config['default']['timezone'] ?? '', 'Bad default network timezone syntax', Configuration::REGEX_TIMEZONE);
        Configuration::assert(Configuration::TYPE_STRING, $config['coordination']['hostname'] ?? '', 'Bad coordination hostname type');
        $this->config = $config;

        return $this;
    }
}
