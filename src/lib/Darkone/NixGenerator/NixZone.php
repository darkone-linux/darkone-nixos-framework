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
     * @throws NixException
     */
    public function buildExtraZoneConfig(Configuration $globalConfig): array
    {
        return [
            'name' => $this->name,

             // Force nix empty list (and not attrset) if no item in services
            'sharedServices' => empty($this->services) ? new NixList() : array_values($this->services),
        ] + ($this->name === Configuration::EXTERNAL_ZONE_KEY ? [
            'globalServices' => $this->buildGlobalServices($globalConfig) ?? (new NixList()),
            'address' => $this->buildAddressList($globalConfig) ?? (new NixList()),
        ] : [
            'extraDnsmasqSettings' => [
                'dhcp-host' => array_values($this->macAddresses),
                'dhcp-range' => $this->dhcpRange,
                'address' => $this->buildAddresses($globalConfig),

                // Do not works with fqdn configuration of dnsmasq -> address
                // 'cname' => $this->buildCnames(),
            ],
            'local-substituter' => $this->substituter,
        ]);
    }

    private function buildGlobalServices(Configuration $globalConfig): ?array
    {
        $globalServices = [];
        foreach ($this->network->getZones() as $zone) {
            foreach ($zone->getServices() as $service) {
                if ($service['global'] ?? false) {
                    unset($service['global']);
                    $host = $globalConfig->getHosts()[$service['host']];
                    $service['targetIp'] = $host->getIp();
                    $globalServices[] = $service;
                }
            }
        }

        return empty($globalServices) ? null : $globalServices;
    }

    /**
     * Address list for TLS
     * @param Configuration $globalConfig
     * @return array|null
     */
    private function buildAddressList(Configuration $globalConfig): ?array
    {
        $address = [];
        foreach ($this->network->getZones() as $zone) {
            if ($zone->getName() == Configuration::EXTERNAL_ZONE_KEY) {
                continue;
            }
            foreach ($zone->getAliases() as $alias) {
                $alias = array_filter($alias, fn (string $name) => empty($zone->getServices()[$name]['global']));
                $address += array_map(fn (string $name) => $name . '.' . $zone->getDomain(), $alias);
            }
        }

        // Hosts: useless?
//        foreach ($globalConfig->getHosts() as $host) {
//            $fqdn = $host->getHostname() . '.' . $host->getZoneDomain();
//            if (in_array($fqdn, $address)) {
//                throw new NixException('Host & service "' . $fqdn . '" conflict');
//            }
//            $address[] = $fqdn;
//        }

        return empty($address) ? null : $address;
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
     * TODO: voir si on étend aux global services des autres zones...
     * @param Configuration $globalConfig
     * @return array
     * @throws NixException
     */
    private function buildAddresses(Configuration $globalConfig): array
    {
        $addresses = [];
        $globalServices = [];
        foreach ($this->getServices() as $service) {
            if ($service['global'] ?? false) {
                $globalServices[$service['domain']] = $globalConfig->getHosts()[$service['host']]->getIp();
            }
        }

        // Main hosts
        foreach ($this->hosts as $host => $ip) {
            if (!empty($ip)) {
                $addresses[] = '/' . $host . '/' . $ip; // host
                // $addresses[] = '/' . $host . '.' . $this->network->getDomain() . '/' . $ip; // host.domain.tld
                $addresses[] = '/' . $host . '.' . $this->config['domain'] . '/' . $ip; // host.zone.domain.tld
            }
        }

        // Replace cnames
        foreach ($this->aliases as $host => $aliases) {
            foreach ($aliases as $alias) {
                $addresses[] = '/' . $alias . '/' . $this->hosts[$host];
                $addresses[] = isset($globalServices[$alias])
                    ? '/' . $alias . '.' . $this->network->getDomain() . '/' . $globalServices[$alias]
                    : '/' . $alias . '.' . $this->config['domain'] . '/' . $this->hosts[$host];
            }
        }

        // External (internet) zone global hosts
        // -> Usefull to contact external hosts without configured DNS / Headscale service
        $globalZone = $this->network->getZone(Configuration::EXTERNAL_ZONE_KEY);
        foreach ($globalZone->getAliases() as $host => $aliases) {
            foreach ($aliases as $alias) {
                $addresses[] = '/' . $alias . '/' . $this->hosts[$host];
                $addresses[] = '/' . $alias . '.' . $this->network->getDomain() . '/' . $this->hosts[$host];
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
        array_map(
            fn (string $name) => Configuration::assertUniqName($name, 'host "' . $host . '" alias', $this->getName()),
            $aliases
        );
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
            $this->services[$service['domain'] ?? $serviceKey] = array_filter([
                'host' => $host,
                'service' => $serviceKey,
                'domain' => $service['domain'] ?? null,
                'title' => $service['title'] ?? null,
                'description' => $service['description'] ?? null,
                'icon' => $service['icon'] ?? null,
                'global' => $service['global'] ?? null,
            ]);
        }

        return $this;
    }

    /**
     * TODO: check
     * @throws NixException
     */
    public function registerZoneConfig(array $cfg): NixZone
    {
        $isLocal = $this->name !== Configuration::EXTERNAL_ZONE_KEY;

        // www + local zones
        $cfg['locale'] ??= $this->network->getDefaultLocale();
        $cfg['lang'] ??= substr($cfg['locale'], 0, 2);
        $cfg['timezone'] ??= $this->network->getDefaultTimezone();
        $cfg['domain'] = $isLocal
            ? $this->name . '.' . $this->network->getDomain()
            : $this->network->getDomain();

        // Exit if www zone
        if ($isLocal) {

            // IPs, domain
            $cfg['ipPrefix'] ??= self::DEFAULT_LAN_IP_PREFIX;
            $cfg['networkIp'] = $cfg['ipPrefix'] . '.0.0';
            $cfg['prefixLength'] = self::LAN_PREFIX_LENGTH;

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
                $this->registerSharedServices($hostname, $hostCfg['services'] ?? []);
                $this->registerAliases($hostname, $hostCfg['aliases'] ?? []);
            }
            unset($cfg['extraHosts']);

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
        isset($gateway['vpn']['ipv4']) && Configuration::assertTailscaleIp($gateway['vpn']['ipv4']);
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
     * @return array
     */
    public function getServices(): array
    {
        return $this->services;
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

    public function getAliases(): array
    {
        return $this->aliases;
    }
}
