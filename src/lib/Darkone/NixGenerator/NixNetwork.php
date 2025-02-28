<?php

namespace Darkone\NixGenerator;

/**
 * @todo integrity tests + unit tests
 */
class NixNetwork
{
    // Mac addresses for dhcp
    private array $macAddresses = [];

    // Hosts with aliases
    private array $aliases = [];
    private array $allAliases = [];

    // Hosts with ips
    private array $hosts = [];

    public function buildExtraNetworkConfig(): array
    {
        return [
            'dhcp-host' => array_values($this->macAddresses),
            'hosts' => $this->buildHostsWithAliases(),
        ];
    }

    private function buildHostsWithAliases(): array
    {
        $config = [];
        natsort($this->hosts);
        foreach ($this->hosts as $host => $ip) {
            if (is_null($ip)) {
                continue;
            }
            $config[$ip] = array_merge([$host], $this->aliases[$host] ?? []);
            sort($config[$ip]);
        }

        return $config;
    }

    /**
     * @throws NixException
     */
    public function registerMacAddress(string $mac, string $ip, string $host): NixNetwork
    {
        if (isset($this->macAddresses[$mac])) {
            throw new NixException('Mac address ' . $mac . ' already declared');
        }
        if (!empty($mac)) {
            $this->macAddresses[$mac] = $mac . ',' . $ip . ',' . $host . ',infinite';
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
        $this->registerHost(
            $cfg['gateway']['hostname'] ?? '',
            $cfg['gateway']['interfaces']['lan']['ip'] ?? null,
            true
        );
        foreach ($cfg['extraHosts'] ?? [] as $hostname => $hostCfg) {
            $this->registerAliases($hostname, $hostCfg['aliases'] ?? []);
            $this->registerHost($hostname, $hostCfg['interfaces'][0]['ip'] ?? null);
            foreach ($hostCfg['interfaces'] ?? [] as $interface) {
                $this->registerMacAddress($interface['mac'] ?? '', $interface['ip'], $hostname);
            }
        }

        return $this;
    }
}