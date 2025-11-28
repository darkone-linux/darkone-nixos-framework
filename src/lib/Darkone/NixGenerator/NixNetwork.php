<?php

namespace Darkone\NixGenerator;

/**
 * @todo integrity tests + unit tests
 */
class NixNetwork
{
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

    public function getDefaultLocale(): string
    {
        return $this->getConfig()['default']['locale'];
    }

    public function getDefaultTimezone(): string
    {
        return $this->getConfig()['default']['timezone'];
    }

    public function getCoordinationDomainName(): string
    {
        return $this->getConfig()['coordination']['domainName'];
    }

    public function getMagicDnsSubDomain(): string
    {
        return $this->getConfig()['coordination']['magicDnsSubDomain'];
    }

    /**
     * @param array $config
     * @return $this
     * @throws NixException
     */
    public function registerNetworkConfig(array $config): NixNetwork
    {
        // Default values
        $config['domain'] ??= Configuration::DEFAULT_DOMAIN;
        $config['default']['locale'] ??= Configuration::DEFAULT_LOCALE;
        $config['default']['timezone'] ??= Configuration::DEFAULT_TIMEZONE;
        $config['coordination']['enable'] ??= false;
        $config['coordination']['domainName'] ??= Configuration::DEFAULT_COORDINATION_DOMAIN_NAME;
        $config['coordination']['magicDnsSubDomain'] ??= Configuration::DEFAULT_MAGIC_DNS_SUB_DOMAIN;

        // Values types
        Configuration::assert(Configuration::TYPE_STRING, $config['domain'], 'Bad network domain type');
        Configuration::assert(Configuration::TYPE_STRING, $config['default']['locale'], 'Bad default network locale syntax', Configuration::REGEX_LOCALE);
        Configuration::assert(Configuration::TYPE_STRING, $config['default']['timezone'], 'Bad default network timezone syntax', Configuration::REGEX_TIMEZONE);
        Configuration::assert(Configuration::TYPE_STRING, $config['coordination']['hostname'] ?? '', 'Bad coordination hostname type', Configuration::REGEX_HOSTNAME);
        Configuration::assert(Configuration::TYPE_STRING, $config['coordination']['domainName'] ?? '', 'Bad Headscale domaine name', Configuration::REGEX_HOSTNAME);
        Configuration::assert(Configuration::TYPE_STRING, $config['coordination']['magicDnsSubDomain'] ?? '', 'Bad Headscale magicDnsSubDomain', Configuration::REGEX_HOSTNAME);
        Configuration::assert(Configuration::TYPE_BOOL, $config['coordination']['enable'], 'Bad coordination enable type');

        // Unknown keys detection
        $testConfig = $config;
        unset(
            $testConfig['domain'],
            $testConfig['default']['locale'],
            $testConfig['default']['timezone'],
            $testConfig['default']['password-hash'], // Auto-generated
            $testConfig['coordination']['hostname'],
            $testConfig['coordination']['enable'],
            $testConfig['coordination']['domainName'],
            $testConfig['coordination']['magicDnsSubDomain']
        );
        if (!empty($testConfig['default'])) {
            throw new NixException('Unknown keys in "network.default" section: ' . json_encode($testConfig['default']));
        }
        unset($testConfig['default']);
        if (!empty($testConfig['coordination'])) {
            throw new NixException('Unknown keys in "network.default" section: ' . json_encode($testConfig['coordination']));
        }
        unset($testConfig['coordination']);
        if (!empty($testConfig)) {
            throw new NixException('Unknown keys in "network" section: ' . json_encode($testConfig));
        }

        // Register network configuration
        $this->config = $config;

        return $this;
    }
}
