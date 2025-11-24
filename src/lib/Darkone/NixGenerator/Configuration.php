<?php

namespace Darkone\NixGenerator;

use Darkone\NixGenerator\Item\Host;
use Darkone\NixGenerator\Item\User;
use Darkone\NixGenerator\Token\NixAttrSet;
use Symfony\Component\Yaml\Yaml;

class Configuration extends NixAttrSet
{
    use ConfigurationAssertTrait;

    public const string TYPE_STRING = 'string';
    public const string TYPE_BOOL = 'boolean';
    public const string TYPE_ARRAY = 'array';
    public const string TYPE_INT = 'integer';
    public const string TYPE_EMAIL = 'email';

    public const string REGEX_HOSTNAME = '/^[a-zA-Z][a-zA-Z0-9_-]{1,59}$/';
    public const string REGEX_LOGIN = '/^[a-zA-Z][a-zA-Z0-9_-]{1,59}$/';
    public const string REGEX_IDENTIFIER = '/^[a-z][a-zA-Z0-9-]{0,62}[a-zA-Z0-9]$/';
    public const string REGEX_DEVICE = '#^/dev(/[a-zA-Z0-9]+){1,3}$#';
    public const string REGEX_MAC_ADDRESS = '[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}';
    public const string REGEX_NAME = '/^.{3,128}$/';
    public const string REGEX_IPV4 = '/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/';
    public const string REGEX_LOCALE = '/^[a-z][a-z]_[A-Z][A-Z]\.UTF-8$/';
    public const string REGEX_TIMEZONE = '/^([A-Za-z]+)\/([A-Za-z0-9_-]+)(?:\/([A-Za-z0-9_-]+))?$/';

    public const string EXTERNAL_ZONE_KEY = 'www';
    public const string DEFAULT_LOCALE = 'fr_FR.UTF-8';
    public const string DEFAULT_TIMEZONE = 'Europe/Paris';

    private const int MAX_RANGE_BOUND = 1000;

    private const string DEFAULT_PROFILE = 'minimal';

    // Nix user login name
    private const string NIX_USER_NAME = 'nix';

    // Nix special user is installed on each host
    private const array NIX_USER_PARAMS = [
        'uid' => 65000,
        'name' => 'Nix Maintenance User',
        'profile' => 'nix-admin',
    ];

    private string $formatter = 'nixfmt';

    /**
     * @var User[]
     */
    private array $users = [];

    /**
     * @var Host[]
     */
    private array $hosts = [];

    /**
     * @var NixZone[]
     */
    private array $zones = [];
    private NixNetwork $network;

    private array $networkConfig = [];
    private array $config; // Global configuration from yaml file

    public function __construct()
    {
        $this->network = new NixNetwork();
        parent::__construct();
    }

    /**
     * Load nix configuration
     * @throws NixException
     */
    public function loadYamlFiles(string $configFile, string $generatedConfigFile): Configuration
    {
        $config = Yaml::parseFile($configFile);
        $this->config = array_replace_recursive($config, Yaml::parseFile($generatedConfigFile));
        $this->loadNetwork($this->config);
        $this->loadZones($this->config);
        $this->loadUsers($this->config);
        $this->loadHosts($this->config);

        return $this;
    }

    public function getFormatter(): string
    {
        return $this->formatter;
    }

    /**
     * @throws NixException
     */
    private function loadUsers(array $config): void
    {
        self::assert(self::TYPE_ARRAY, $config['users'] ?? null, "Users not found in configuration");
        $config['users'][self::NIX_USER_NAME] = self::NIX_USER_PARAMS;
        foreach ($config['users'] as $login => $user) {
            self::assertUserInput($login, $user);
            $this->users[$login] = (new User())
                ->setUidAndLogin($user['uid'], $login)
                ->setEmail($user['email'] ?? $login . '@' . $this->getNetwork()->getDomain())
                ->setName($user['name'])
                ->setProfile($user['profile'] ?? self::DEFAULT_PROFILE)
                ->setGroups($user['groups'] ?? []);
        }
    }

    /**
     * @throws NixException
     */
    private function loadHosts(array $config): void
    {
        if (!isset($config['hosts'])) {
            return;
        }
        self::assert(self::TYPE_ARRAY, $config['hosts'], "Bad hosts root value");

        $hosts = [];
        foreach ($config['hosts'] as $host) {
            $type = isset($host['range'])
                ? 'range'
                : (isset($host['hosts'])
                    ? 'list'
                    : 'static');
            $hosts[$type][] = $host;
        }

        $this->loadStaticHosts($hosts['static'] ?? []);
        $this->loadRangeHosts($hosts['range'] ?? []);
        $this->loadListHosts($hosts['list'] ?? []);

        // Add gateway host name + hosts and ips
        $this->populateZones();
    }

    /**
     * @throws NixException
     */
    private function loadStaticHosts(array $staticHosts): void
    {
        foreach ($staticHosts as $host) {
            $this->assertHostInput($host);
            list($zoneName, $ip) = $this->extractZoneAndIp($host);
            self::assertHostName($host['hostname']);
            $zone = $this->zones[$zoneName];
            $this->hosts[$host['hostname']] = (new Host())
                ->setHostname($host['hostname'])
                ->setName($host['name'])
                ->setZone($zoneName)
                ->setProfile($host['profile'])
                ->setArch($host['arch'] ?? null)
                ->setNetworkDomain($zone->getName() == self::EXTERNAL_ZONE_KEY ? $this->network->getDomain() : $zone->getDomain())
                ->setNfsClient($host['nfsClient'] ?? false)
                ->setUsers($this->extractAllUsers($host['users'] ?? [], $host['groups'] ?? []))
                ->setGroups($host['groups'] ?? [])
                ->setTags($host['tags'] ?? [])
                ->registerAliases($zone, $host['aliases'] ?? [])
                ->registerHostInZone($zone, $host, $ip)
                ->registerServices($zone, $host['services'] ?? [])
                ->setIp($ip)
                ->setDisko($host['disko'] ?? []);
        }
    }

    private function extractAllUsers(array $hostUsers, array $groups): array
    {
        $users = [self::NIX_USER_NAME];
        foreach ($hostUsers as $login) {
            $users[] = $login;
        }
        foreach ($groups as $group) {
            foreach ($this->getUsers() as $user) {
                if (in_array($group, $user->getGroups())) {
                    $users[] = $user->getLogin();
                }
            }
        }

        sort($users, SORT_STRING);
        return array_unique($users);
    }

    private function loadRangeHosts(array $rangeHosts): void
    {
        array_map(/**
         * @throws NixException
         */ fn (array $hostGroup) => $this->buildRangeHostGroup($hostGroup), $rangeHosts);
    }

    /**
     * @throws NixException
     */
    private function buildRangeHostGroup(array $rangeHostGroup): void
    {
        $range = self::assert(self::TYPE_ARRAY, $rangeHostGroup['range'], "Bad range type");
        if (count($range) !== 2 || !is_int($range[0]) || !is_int($range[1])) {
            throw new NixException('Bad range [' . $range[0] . ', ' . $range[0] . ']');
        }
        $count = $range[1] - $range[0];
        if ($count < 0 || $count > self::MAX_RANGE_BOUND) {
            throw new NixException('Range [' . $range[0] . ', ' . $range[0] . '] out of bound');
        }

        $hosts = [];
        for ($i = $range[0]; $i <= $range[1]; $i++) {
            $hosts[$i] = [
                'hostname' => sprintf($rangeHostGroup['hostname'], $i),
                'name' => sprintf($rangeHostGroup['name'], $i),
                'zone' => sprintf($rangeHostGroup['zone'], $i),
                'profile' => $rangeHostGroup['profile'],
                'users' => $rangeHostGroup['users'] ?? [],
                'groups' => $rangeHostGroup['groups'] ?? [],
                'tags' => $rangeHostGroup['tags'] ?? [],
                'disko' => $rangeHostGroup['disko'] ?? [],
                'nfsClient' => $rangeHostGroup['nfsClient'] ?? false,
            ];
            if (!empty($rangeHostGroup['mac'][$i])) {
                $hosts[$i]['mac'] = $rangeHostGroup['mac'][$i];
            }
        }

        foreach ($rangeHostGroup['hosts'] ?? [] as $id => $extraConfig) {
            $hosts[$id] += $extraConfig;
        }

        $this->loadStaticHosts($hosts);
    }

    private function loadListHosts(array $listHosts): void
    {
        array_map(/**
         * @throws NixException
         */ fn (array $hostGroup) => $this->buildListHostGroup($hostGroup), $listHosts);
    }

    /**
     * @throws NixException
     */
    private function buildListHostGroup(array $listHostGroup): void
    {
        $list = self::assert(self::TYPE_ARRAY, $listHostGroup['hosts'], "Bad hosts list type");
        $hosts = [];
        foreach ($list as $hostname => $hostCfg) {
            self::assert(self::TYPE_STRING, $hostname, "Bad host name (hostname key)", self::REGEX_HOSTNAME);
            self::assert(self::TYPE_ARRAY, $hostCfg, "Bad host configuration type");
            self::assert(self::TYPE_STRING, $hostCfg['name'], "Bad host description (name) type", self::REGEX_NAME);
            $hosts[] = array_merge($hostCfg, [
                'hostname' => sprintf($listHostGroup['hostname'] ?? "%s", $hostname),
                'name' => sprintf($listHostGroup['name'] ?? "%s", $hostCfg['name']),
                'profile' => $listHostGroup['profile'],
                'users' => $listHostGroup['users'] ?? [],
                'groups' => $listHostGroup['groups'] ?? [],
                'tags' => $listHostGroup['tags'] ?? [],
                'disko' => $listHostGroup['disko'] ?? [],
                'nfsClient' => $listHostGroup['nfsClient'] ?? false,
            ]);
        }
        $this->loadStaticHosts($hosts);
    }

    /**
     * @throws NixException
     */
    public function populateZones(): void
    {
        foreach ($this->hosts as $host) {

            // Add gateway
            str_ends_with($host->getIp() ?? '', '.1.1') &&
                $this->zones[$host->getZone()]->setGateway($host);

            // Add www hosts in dnsmasq config
            // TODO: To be deleted when headscale is operational
            if ($host->getZone() === self::EXTERNAL_ZONE_KEY) {
                foreach ($this->zones as $zone) {
                    if ($zone->getName() !== self::EXTERNAL_ZONE_KEY) {
                        $zone->registerHost($host->getHostname(), $host->getIp());
                    }
                }
            }
        }
    }

    /**
     * @return User[]
     */
    public function getUsers(): array
    {
        return $this->users;
    }

    /**
     * @throws NixException
     */
    public function getUser(string $login): User
    {
        if (!isset($this->users[$login])) {
            throw new NixException('User "' . $login . '" not found');
        }
        return $this->users[$login];
    }

    /**
     * @return Host[]
     */
    public function getHosts(): array
    {
        return $this->hosts;
    }

    /**
     * @throws NixException
     */
    public function loadNetwork(array $config): Configuration
    {
        $this->networkConfig = $this->network->registerNetworkConfig($config['network'] ?? [])->getConfig();
        return $this;
    }

    /**
     * @throws NixException
     */
    public function loadZones(array $config): Configuration
    {
        // Special www zone (internet)
        $zone = new NixZone(self::EXTERNAL_ZONE_KEY, $this->network);
        $zone->registerZoneConfig([]);
        $this->zones[self::EXTERNAL_ZONE_KEY] = $zone;

        foreach ($config['zones'] ?? [] as $zoneName => $zoneConfig) {
            if ($zoneName === 'common') {
                continue;
            }
            $config['zones'][$zoneName] = array_merge_recursive($zoneConfig, $config['zones']['common'] ?? []);
            $zone = new NixZone($zoneName, $this->network);
            $zone->registerZoneConfig($zoneConfig);
            $this->zones[$zoneName] = $zone;
        }

        return $this;
    }

    public function getNetworkConfig(): array
    {
        return $this->networkConfig;
    }

    /**
     * @return NixZone[]
     * @throws NixException
     */
    public function extractZonesConfig(): array
    {
        $zones = [];
        foreach ($this->zones as $zoneName => $zone) {
            $zones[$zoneName] = $zone->getConfig() + $this->network->getZone($zoneName)->buildExtraZoneConfig();
        }

        return $zones;
    }

    /**
     * @param array $host
     * @return array
     * @throws NixException
     */
    public function extractZoneAndIp(array $host): array
    {
        if (!empty($host['zone'])) {
            [$zoneName, $ip] = explode(':', $host['zone'] . ':');
            $ip = empty($ip) ? null : $this->zones[$zoneName]->getConfig()['ipPrefix'] . '.' . $ip;
            if (!is_null($ip) && (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) || !str_starts_with($ip, '10.'))) {
                throw new NixException(
                    'Generated IP address "' . $ip . '" for host "' . $host['hostname'] . '" is not a valid local IP.'
                );
            }
        } else {
            $zoneName = self::EXTERNAL_ZONE_KEY;
            $ip = $host['ipv4'];
            if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
                throw new NixException(
                    'Generated address "' . $ip . '" for host "' . $host['hostname'] . '" is not a valid external IP.'
                );
            }
        }
        return [$zoneName, $ip];
    }

    /**
     * @return NixZone[]
     */
    public function getZones(): array
    {
        return $this->zones;
    }

    public function getNetwork(): NixNetwork
    {
        return $this->network;
    }
}
