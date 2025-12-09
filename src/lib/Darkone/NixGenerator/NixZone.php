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

    // Other options
    private array $dhcpRange = [];

    // Updated configuration
    private array $config = [];

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
     * @param Configuration $globalConfig
     * @return array
     * @throws NixException
     */
    public function buildExtraZoneConfig(Configuration $globalConfig): array
    {
        return [
            'name' => $this->name,
        ] + ($this->name === Configuration::EXTERNAL_ZONE_KEY ? [
            'address' => $this->buildAddressList() ?? (new NixList()),
        ] : [
            'extraDnsmasqSettings' => [
                'dhcp-host' => array_values($this->macAddresses),
                'dhcp-range' => $this->dhcpRange,

                // Toutes les adresses en *zoneCourante.domain.tld sons résolues avec l'adresse du gateway
                'address' => ['/' . $this->getDomain() . '/' . $this->getConfig()['gateway']['lan']['ip']],

                // Toutes les adresses en *autresZone.domain.tld sont redirigées vers le gateway de la zone
                'server' => $this->buildServers(),

                // A + PTR
                'host-record' => $this->buildHostRecordList($globalConfig),

                // Do not works with fqdn configuration of dnsmasq -> address
                // 'cname' => $this->buildCnames(),
            ],
        ]);
    }

    /**
     * Address list for TLS
     * @return array|null
     */
    private function buildAddressList(): ?array
    {
        $address = array_values(
            array_map(
                fn (NixService $service) => $service->getFqdn($this->network),
                array_filter(
                    $this->network->getServices(),
                    fn (NixService $service) => !$service->isGlobal())));

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
     * @return array
     */
    private function buildServers(): array
    {
        $servers = [];
        foreach ($this->network->getZones() as $zone) {

            // Pour la zone courante -> "address"
            if ($zone->getName() === $this->getName()) {
                continue;
            }

            // Pas besoin du HCS
            // TODO: voir si le HCS ne pourrait pas récupérer la résolution du domaine principal
            if ($zone->getName() === Configuration::EXTERNAL_ZONE_KEY) {
                continue;
            }

            // --server pour tous les autres subnets
            $servers[] = '/' . $zone->getDomain() . '/' . $zone->getConfig()['gateway']['lan']['ip'];
        }

        return $servers;
    }

    /**
     * TODO: voir si on étend aux global services des autres zones...
     * @param Configuration $config
     * @return array
     * @throws NixException
     */
    private function buildHostRecordList(Configuration $config): array
    {
        $hostRecords = [];

        foreach ($this->network->getServices() as $service) {
            $domain = $service->getDomain() ?? $service->getName();
            $srvZone = $this->network->getZones()[$service->getZone()];
            $srvHost = $config->getHosts()[$service->getHost()];
            $needVpnIp = $srvZone->getName() === Configuration::EXTERNAL_ZONE_KEY
                && !in_array($service->getName(), NixService::EXTERNAL_ACCESS_SERVICES);
            $targetIsGateway = $srvZone->getName() !== Configuration::EXTERNAL_ZONE_KEY
                && in_array($service->getName(), NixService::REVERSE_PROXY_SERVICES);

            // Les services à proxier pointent vers le gateway tandis que les services
            // à accès direct qui hébergés à l'extérieur doivent être résolus vers l'hôte qui les hébergent.
            // 1. Dans une zone et la cible doit être le gateway -> gateway de la zone
            // 2. A l'extérieur d'une zone mais dans le tailnet -> adresse interne du VPN / Tailnet
            // 3. Sinon -> adresse interne de l'hôte qui héberge le service
            $ip = $targetIsGateway
                ? $srvZone->getConfig()['ipPrefix'] . '.1.1'
                : ($needVpnIp ? $srvHost->getVpnIp() : $srvHost->getIp());

            // Unqualified names for services of current zone
            $hr = $this->getName() == $srvZone->getName() ? $domain . ',' : '';

            // Full qualified names for all services
            $hostRecords[] =  $hr . $service->getFqdn($this->network) . ',' . $ip;
        }

        // Full hosts to complete tailnet magic dns list
        $hostRecords = array_merge($hostRecords, Configuration::getHostRecords());

        // Host aliases
        // TODO: les alias sont-ils vraiment utiles à l'heure actuelle ?
        foreach ($this->aliases as $host => $aliases) {
            foreach ($aliases as $alias) {
                $hostRecords[] = $alias . ',' . $alias . '.' . $this->getDomain() . ',' . $this->hosts[$host];
            }
        }

        // External (internet) zone global hosts
        // -> Usefull to contact external hosts without configured DNS / Headscale service
        $globalZone = $this->network->getZone(Configuration::EXTERNAL_ZONE_KEY);
        foreach ($globalZone->getAliases() as $host => $aliases) {
            foreach ($aliases as $alias) {
                $hostRecords[] = $alias . ',' . $alias . '.' . $this->network->getDomain() . ',' . $this->hosts[$host];
            }
        }

        // Hosts résiduels -> extra hosts (non-nix)
        $hosts = array_filter($this->hosts);
        foreach ($hostRecords as $record) {
            $name = explode(',', $record)[0];
            unset ($hosts[$name]);
        }
        foreach ($hosts as $host => $ip) {
            $hostRecords[] =  $host . ',' . $host . '.' . $this->getDomain() . ',' . $this->hosts[$host];
        }

        sort($hostRecords);

        return $hostRecords;
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
                $this->network->registerServices(
                    (new Host())
                        ->setName($hostname)
                        ->setZone($this->getName())
                        ->setServices($hostCfg['services'] ?? []));
                $this->registerAliases($hostname, $hostCfg['aliases'] ?? []);

                // Only NixOS hosts (for management)
                // Configuration::addToFullHostIps($hostname, $hostIp);
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
