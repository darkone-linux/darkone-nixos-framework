<?php

namespace Darkone\NixGenerator;

use Darkone\NixGenerator\Item\Host;

/**
 * @todo integrity tests + unit tests
 */
class NixNetwork
{
    private array $config;
    private array $zones = [];

    /**
     * @var NixService[]
     */
    private array $services = [];

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
        return $this->getConfig()['coordination']['domain'];
    }

    public function getCoordinationHostname(): string
    {
        return $this->getConfig()['coordination']['hostname'];
    }

    /**
     * @return NixService[]
     */
    public function getServices(): array
    {
        return $this->services;
    }

    /**
     * @return array
     */
    public function servicesToArray(): array
    {
        return array_values(array_map(fn (NixService $service) => $service->toArray(), $this->services));
    }

    /**
     * @param Host $host
     * @return $this
     * @throws NixException
     */
    public function registerServices(Host $host): NixNetwork
    {
        static $uniqServices = [];
        static $globalServices = [];

        foreach ($host->getServices() as $serviceName => $service) {
            $isGlobal = $service['global'] ?? null;
            $serviceDomain = $service['domain'] ?? $serviceName;

            // Check services that must be unique per zone
            if (in_array($serviceName, NixService::UNIQUE_SERVICES_BY_ZONE)) {
                if (isset($uniqServices[$host->getZone()][$serviceName])) {
                    throw new NixException('Service ' . $serviceName . ' must be unique in zone ' . $host->getZone());
                }
                $uniqServices[$host->getZone()][$serviceName] = true;
            }

            // Check name conflict for global services
            if ($host->getZone() === Configuration::EXTERNAL_ZONE_KEY) {
                if (!is_null($isGlobal)) {
                    throw new NixException(
                        'External service "' . $serviceName . '" is necessarily global. Remove the "global" key.'
                    );
                }
                $isGlobal = true;
            }

            // Global explicitly specified for an implicitly global external service -> fail
            if ($isGlobal) {
                if (in_array($serviceDomain, $globalServices)) {
                    throw new NixException('Global services domain name conflict: ' . $serviceName);
                }
                $globalServices[] = $serviceDomain;
            }

            // Register substituter for special service NCPS
            if ($serviceName == 'ncps') {
                $this->getZones()[$host->getZone()]->setSubstituter($host->getHostname());
            }

            // Build service key to detect domain conflicts
            $key = $host->getZone() . ':' . $serviceDomain;
            if (array_key_exists($key, $this->services)) {
                throw new NixException('Service name conflict: ' . $key);
            }

            // Register new service
            $this->services[$key] = (new NixService())
                ->setName($serviceName)
                ->setHost($host->getHostname())
                ->setZone($host->getZone())
                ->setDomain($service['domain'] ?? null)
                ->setTitle($service['title'] ?? null)
                ->setDescription($service['description'] ?? null)
                ->setIcon($service['icon'] ?? null)
                ->setGlobal($isGlobal ?? false);
        }

        return $this;
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
        $config['coordination']['domain'] ??= Configuration::DEFAULT_COORDINATION_DOMAIN;

        // Values types
        Configuration::assert(Configuration::TYPE_STRING, $config['domain'], 'Bad network domain type');
        Configuration::assert(Configuration::TYPE_STRING, $config['default']['locale'], 'Bad default network locale syntax', Configuration::REGEX_LOCALE);
        Configuration::assert(Configuration::TYPE_STRING, $config['default']['timezone'], 'Bad default network timezone syntax', Configuration::REGEX_TIMEZONE);
        Configuration::assert(Configuration::TYPE_STRING, $config['coordination']['hostname'] ?? '', 'Bad coordination hostname type', Configuration::REGEX_HOSTNAME);
        Configuration::assert(Configuration::TYPE_STRING, $config['coordination']['domain'] ?? '', 'Bad Headscale domaine name', Configuration::REGEX_HOSTNAME);
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
            $testConfig['coordination']['domain'],
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
