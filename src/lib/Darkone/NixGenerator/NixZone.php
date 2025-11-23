<?php

namespace Darkone\NixGenerator;

use Darkone\NixGenerator\Item\Host;
use Darkone\NixGenerator\Token\NixList;

/**
 * @todo integrity tests + unit tests
 */
class NixZone
{
    private const string DEFAULT_LAN_IP_PREFIX = '10.1';
    private const int LAN_PREFIX_LENGTH = 16;

    // Name of current zone
    private string $name;

    // Mac addresses for dhcp
    private array $macAddresses = [];

    // Hosts with aliases
    private array $aliases = [];
    private array $allAliases = [];

    // Hosts with ips
    private array $hosts = [];

    // Shared services informations
    private array $services = [];

    // Other options
    private array $dhcpOption = [];
    private array $dhcpRange = [];

    // Updated configuration
    private array $config = [];

    // NCPS service provider
    private ?string $substituter = null;

    private NixNetwork $network;

    /**
     * @param string $name
     * @param NixNetwork $network
     */
    public function __construct(string $name, NixNetwork $network)
    {
        $this->name = $name;
        $this->network = $network;
    }

    /**
     * @return array
     */
    public function buildExtraZoneConfig(): array
    {
        // Force nix empty list (and not attrset) if no item in services
        $services = empty($this->services) ? new NixList() : $this->services;

        return $this->name === Configuration::EXTERNAL_ZONE_KEY ? [
            'sharedServices' => $services,
        ] : [
            'extraDnsmasqSettings' => [
                'dhcp-host' => array_values($this->macAddresses),
                'dhcp-option' => $this->dhcpOption,
                'dhcp-range' => $this->dhcpRange,
                'address' => $this->buildAddresses(),

                // Do not works with fqdn configuration of dnsmasq -> address
                // 'cname' => $this->buildCnames(),
            ],
            'sharedServices' => $services,
            'local-substituter' => $this->substituter,
        ];
    }

    /**
     * @deprecated ?
     * @return array
     */
    private function buildCnames(): array
    {
        $cnames = [];
        foreach ($this->aliases as $host => $aliases) {
            $hostCnames = [];
            foreach ($aliases as $alias) {
                $hostCnames[] = $alias . ',' . $host . '.' . $this->config['domain'];
                $hostCnames[] = $alias . '.' . $this->config['domain'] . ',' . $host . '.' . $this->config['domain'];
            }
            sort($hostCnames);
            $cnames = array_merge($cnames, $hostCnames);
        }

        return $cnames;
    }

    /**
     * @return array
     */
    private function buildAddresses(): array
    {
        $addresses = [];

        // Main hosts
        foreach ($this->hosts as $host => $ip) {
            if (!empty($ip)) {
                $addresses[] = '/' . $host . '/' . $ip; // host
                $addresses[] = '/' . $host . '.' . $this->network->getDomain() . '/' . $ip; // host.domain.tld
                $addresses[] = '/' . $host . '.' . $this->config['domain'] . '/' . $ip; // host.zone.domain.tld
            }
        }

        // Replace cnames
        foreach ($this->aliases as $host => $aliases) {
            foreach ($aliases as $alias) {
                $addresses[] = '/' . $alias . '/' . $this->hosts[$host];
                $addresses[] = '/' . $alias . '.' . $this->network->getDomain() . '/' . $this->hosts[$host];
                $addresses[] = '/' . $alias . '.' . $this->config['domain'] . '/' . $this->hosts[$host];
            }
        }

        sort($addresses);

        return $addresses;
    }

    /**
     * @param string $mac
     * @param string $ip
     * @return $this
     * @throws NixException
     */
    public function registerMacAddresses(string $mac, string $ip): NixZone
    {
        static $macAddresses = [];

        $newMacAdresses = explode(',', $mac);
        foreach ($newMacAdresses as $macAdress) {

            // Filter + checks
            if (!preg_match('/^' . Configuration::REGEX_MAC_ADDRESS . '(,' . Configuration::REGEX_MAC_ADDRESS . ')*$/', $macAdress)) {
                throw new NixException('Bad mac address syntax "' . $mac . '"');
            }

            // Duplicates detection
            if (in_array($macAdress, $macAddresses)) {
                throw new NixException('Mac address ' . $macAdress . ' duplicated');
            }
            $macAddresses[] = $macAdress;
        }

        // IP conflict
        if (isset($this->macAddresses[$ip])) {
            throw new NixException('Ip address ' . $ip . ' conflict (mac: ' . $mac . ' vs ' . $this->macAddresses[$ip] . ')');
        }

        # Do not put the name of the host here !
        # The name of the installed OS must be defined by the OS only.
        # Very important for usb keys that contains an OS.
        $this->macAddresses[$ip] = $mac . ',' . $ip;

        return $this;
    }

    /**
     * @throws NixException
     */
    public function registerAliases(string $host, array $aliases): NixZone
    {
        if (!empty($hosts = array_intersect(array_keys($this->aliases), $aliases))) {
            throw new NixException('Alias name(s) ' . implode(', ', $hosts) . ' already declared in main hosts');
        }
        if (!empty($hosts = array_intersect(array_keys($this->hosts), $aliases))) {
            throw new NixException('Name(s) ' . implode(', ', $hosts) . ' cannot be aliases and main host names');
        }
        if (!empty($hosts = array_intersect($this->allAliases, $aliases))) {
            throw new NixException('Duplicated alias(es) ' . implode(', ', $hosts));
        }
        $this->allAliases = array_merge($this->allAliases, $aliases);
        $this->aliases[$host] = array_merge($this->aliases[$host] ?? [], $aliases);

        return $this;
    }

    /**
     * @throws NixException
     */
    public function registerHost(string $host, ?string $ip, bool $force = false): NixZone
    {
        if (empty($host)) {
            return $this;
        }
        if (!$force && isset($this->hosts[$host])) {
            throw new NixException('Hostname ' . $host . ' already declared');
        }
        if (!is_null($ip) && in_array($ip, $this->hosts)) {
            throw new NixException('Ip address ' . $ip . ' assigned to more than one host');
        }
        $this->hosts[$host] = $ip ?? $this->hosts[$host] ?? null;

        return $this;
    }

    /**
     * @throws NixException
     */
    public function registerSharedServices(string $host, array $services): NixZone
    {
        static $serviceDomains = [];

        if (empty($services)) {
            return $this;
        }

        foreach ($services as $serviceKey => $service) {
            if (!empty($service['domain'])) {
                if (in_array($service['domain'], $serviceDomains)) {
                    throw new NixException('Service domain conflict: "' . $service['domain'] . '"');
                }
                $serviceDomains[] = $service['domain'];
            }
            if ($serviceKey == 'ncps') {
                if (!is_null($this->substituter)) {
                    throw new NixException('Cannot have more than 1 ncps provider (' . $host . ' vs ' . $this->substituter . ').');
                }
                $this->substituter = $host;
            }
            $this->services[] = array_filter([
                'host' => $host,
                'service' => $serviceKey,
                'domainName' => $service['domain'] ?? null,
                'displayName' => $service['title'] ?? null,
                'description' => $service['description'] ?? null,
                'icon' => $service['icon'] ?? null,
            ]);
        }

        return $this;
    }

    /**
     * @throws NixException
     */
    public function registerZoneConfig(array $cfg): NixZone
    {
        // www + local zones
        $cfg['locale'] ??= $this->network->getDefaultLocale() ?? Configuration::DEFAULT_LOCALE;
        $cfg['lang'] ??= substr($cfg['locale'], 0, 2);
        $cfg['timezone'] ??= $this->network->getDefaultTimezone() ?? Configuration::DEFAULT_TIMEZONE;

        // Exit if www zone
        if ($this->name !== Configuration::EXTERNAL_ZONE_KEY) {

            // IPs, domain
            $cfg['ipPrefix'] ??= self::DEFAULT_LAN_IP_PREFIX;
            $cfg['networkIp'] = $cfg['ipPrefix'] . '.0.0';
            $cfg['prefixLength'] = self::LAN_PREFIX_LENGTH;
            $cfg['domain'] = $this->name . '.' . $this->network->getDomain();

            // No gateway?
            if (!isset($cfg['gateway']['lan']) && !isset($cfg['gateway']['wan'])) {
                $this->config = $cfg;
                return $this;
            }

            // Checks before using config
            $this->assertGwCfg($cfg['gateway']);

            // Extra hosts (not in nix host list)
            foreach ($cfg['extraHosts'] ?? [] as $hostname => $hostCfg) {
                $hostIp = $cfg['ipPrefix'] . '.' . $hostCfg['ip'];
                $this->registerHost($hostname, $hostIp);
                $this->registerMacAddresses($hostCfg['mac'], $hostIp);
                $this->registerAliases($hostname, $hostCfg['aliases'] ?? []);
                $this->registerSharedServices($hostname, $hostCfg['services'] ?? []);
            }
            unset($cfg['extraHosts']);

            // DHCP Option
            $this->dhcpOption = array_merge([
                "option:router," . $cfg['ipPrefix'] . '.1.1',
                "option:dns-server," . $cfg['ipPrefix'] . '.1.1',
                "option:domain-name," . $cfg['domain'],
                "option:domain-search," . $cfg['domain'],
            ], $cfg['gateway']['lan']['dhcp-extra-option'] ?? []);

            // DHCP Range
            $this->dhcpRange = $cfg['gateway']['lan']['dhcp-range'] ?? [
                $cfg['ipPrefix'] . '.3.200,' . $cfg['ipPrefix'] . '.3.249,24h'
            ];

        } // local zone

        $this->config = $cfg;
        $this->network->addZone($this);

        return $this;
    }

    /**
     * @return array
     */
    public function getConfig(): array
    {
        return $this->config;
    }

    /**
     * @param $gateway
     * @return void
     * @throws NixException
     */
    public function assertGwCfg($gateway): void
    {
        Configuration::assert(
            Configuration::TYPE_STRING,
            $gateway['wan']['interface'] ?? null,
            'A WAN interface is required'
        );
        Configuration::assert(
            Configuration::TYPE_ARRAY,
            $gateway['lan']['interfaces'] ?? null,
            'Valid LAN interfaces are required',
            null,
            Configuration::TYPE_STRING
        );
    }

    /**
     * @return string
     */
    public function getName(): string
    {
        return $this->name;
    }

    /**
     * @return string
     */
    public function getDomain(): string
    {
        return $this->config['domain'];
    }

    /**
     * @param Host $host
     * @return $this
     * @throws NixException
     */
    public function setGateway(Host $host): NixZone
    {
        if (!empty($this->config['gateway']['hostname'])) {
            throw new NixException(
                'Zone "' . $this->getName() . '" already have a gateway "'
                . $this->config['gateway']['hostname'] . '", cannot set "'
                . $host->getHostname() . '"'
            );
        }
        $this->config['gateway']['hostname'] = $host->getHostname();
        $this->config['gateway']['lan']['ip'] = $host->getIp();

        return $this;
    }
}
