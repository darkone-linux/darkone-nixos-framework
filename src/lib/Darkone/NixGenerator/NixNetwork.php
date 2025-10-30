<?php

namespace Darkone\NixGenerator;

/**
 * @todo integrity tests + unit tests
 */
class NixNetwork
{
    private const DEFAULT_LAN_IP = '192.168.9.1';
    private const DEFAULT_LAN_PREFIX_LENGTH = 24;
    private const DEFAULT_DOMAIN = 'darkone.lan';
    private const DEFAULT_TIMEZONE = 'America/Miquelon';
    private const DEFAULT_LOCALE = 'fr_FR.UTF-8';

    // Mac addresses for dhcp
    private array $macAddresses = [];

    // Hosts with aliases
    private array $aliases = [];
    private array $allAliases = [];

    // Hosts with ips
    private array $hosts = [];

    // Other options
    private array $dhcpOption = [];
    private array $dhcpRange = [];

    // Updated configuration
    private array $config = [];

    public function buildExtraNetworkConfig(): array
    {
        return [
            'extraDnsmasqSettings' => [
                'dhcp-host' => array_values($this->macAddresses),
                'dhcp-option' => $this->dhcpOption,
                'dhcp-range' => $this->dhcpRange,
                'cname' => $this->buildCnames(),
            ],
        ];
    }

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
     * @throws NixException
     */
    public function registerMacAddress(string $mac, string $ip, string $host): NixNetwork
    {
        static $macAddresses = [];

        if (!empty($mac)) {

            // Filter + checks
            $mac = trim(strtolower($mac));
            if (!preg_match('/^' . Configuration::REGEX_MAC_ADDRESS . '(,' . Configuration::REGEX_MAC_ADDRESS . ')*$/', $mac)) {
                throw new NixException('Bad mac address syntax for "' . $mac . '"');
            }

            // Duplicates detection
            if (in_array($mac, $macAddresses)) {
                throw new NixException('Mac address ' . $mac . ' already declared');
            }
            $macAddresses[] = $mac;

            // In case of we have this :
            // interfaces:
            // - mac: xxx
            //   ip: "192.168.1.3"
            // - mac: yyy
            //   ip: "192.168.1.3" <- the same
            if (isset($this->macAddresses[$ip])) {
                $record = explode(',', $this->macAddresses[$ip]);
                $registeredHost = $record[count($record) - 2];
                if ($host !== $registeredHost) {
                    throw new NixException('Cannot register a mac address ' . $mac . ' with different host names: ' . $host . ' vs ' . $registeredHost);
                }
                $this->macAddresses[$ip] = $mac . ',' . $this->macAddresses[$ip];
            } else {
                $this->macAddresses[$ip] = $mac . ',' . $ip . ',' . $host . ',infinite';
            }
        }

        return $this;
    }

    /**
     * @throws NixException
     */
    public function registerAliases(string $host, array $aliases): NixNetwork
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
    public function registerHost(string $host, ?string $ip, bool $force = false): NixNetwork
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
    public function registerNetworkConfig(array $cfg): NixNetwork
    {
        $gwStaticIp = $cfg['gateway']['lan']['ip'] ?? self::DEFAULT_LAN_IP;
        $gwIpPrefix = preg_replace('/^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$/', '$1', $gwStaticIp);

        // Rewrite cfg with default options
        $cfg['domain'] ??= self::DEFAULT_DOMAIN;
        $cfg['locale'] ??= self::DEFAULT_LOCALE;
        $cfg['timezone'] ??= self::DEFAULT_TIMEZONE;

        // No gateway?
        if (!isset($cfg['gateway']['lan']) && !isset($cfg['gateway']['wan'])) {
            $this->config = $cfg;
            return $this;
        }

        // Checks before using config
        $this->assertGwCfg($cfg['gateway']);

        // Rewrite gateway cfg with default options
        $cfg['gateway']['lan']['ip'] = $gwStaticIp;
        $cfg['gateway']['lan']['prefixLength'] ??= self::DEFAULT_LAN_PREFIX_LENGTH;

        // Gateway host + static ip
        $this->registerHost($cfg['gateway']['hostname'] ?? '', $gwStaticIp, true);

        // Extra hosts (not in nix host list)
        foreach ($cfg['extraHosts'] ?? [] as $hostname => $hostCfg) {
            $this->registerAliases($hostname, $hostCfg['aliases'] ?? []);
            $this->registerHost($hostname, $hostCfg['interfaces'][0]['ip'] ?? null);
            foreach ($hostCfg['interfaces'] ?? [] as $interface) {
                $this->registerMacAddress($interface['mac'] ?? '', $interface['ip'], $hostname);
            }
        }
        unset($cfg['extraHosts']);

        // DHCP Option
        $this->dhcpOption = array_merge([
            "option:router," . $gwStaticIp,
            "option:dns-server," . $gwStaticIp,
            "option:domain-name," . $cfg['domain'],
            "option:domain-search," . $cfg['domain'],
        ], $cfg['gateway']['lan']['dhcp-extra-option'] ?? []);

        // DHCP Range
        $this->dhcpRange = $cfg['gateway']['lan']['dhcp-range'] ?? [
            $gwIpPrefix . '.200,' . $gwIpPrefix . '.249,24h'
        ];
        $this->config = $cfg;

        return $this;
    }

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
            $gateway['hostname'] ?? null,
            'A gateway valid hostname is required',
            Configuration::REGEX_HOSTNAME
        );
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

    public function getHostIp(string $host): ?string
    {
        return $this->hosts[$host] ?? null;
    }
}
