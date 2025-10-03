<?php

namespace Darkone\NixGenerator;

use Darkone\NixGenerator\Item\Host;
use Darkone\NixGenerator\Item\User;
use Darkone\NixGenerator\Token\NixAttrSet;
use Symfony\Component\Yaml\Yaml;

class Configuration extends NixAttrSet
{
    public const TYPE_STRING = 'string';
    public const TYPE_BOOL = 'boolean';
    public const TYPE_ARRAY = 'array';
    public const TYPE_INT = 'integer';

    public const REGEX_HOSTNAME = '/^[a-zA-Z][a-zA-Z0-9_-]{1,59}$/';
    public const REGEX_LOGIN = '/^[a-zA-Z][a-zA-Z0-9_-]{1,59}$/';
    public const REGEX_NAME = '/^.{3,128}$/';
    public const REGEX_IPV4 = '/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/';

    private const MAX_RANGE_BOUND = 1000;

    private const DEFAULT_PROFILE = 'minimal';

    // Nix user login name
    private const NIX_USER_NAME = 'nix';

    // Nix special user is installed on each host
    private const NIX_USER_PARAMS = [
        'uid' => 65000,
        'name' => 'Nix Maintenance User',
        'profile' => 'nix-admin',
    ];

    private string $formatter = 'nixfmt';
    private ?array $lldapConfig = null;

    /**
     * @var User[]
     */
    private array $users = [];

    /**
     * @var Host[]
     */
    private array $hosts = [];
    private array $networkConfig = [];
    private NixNetwork $extraNetwork;

    public function __construct()
    {
        $this->extraNetwork = new NixNetwork();
        parent::__construct();
    }

    /**
     * Load nix configuration
     * @throws NixException
     */
    public function loadYamlFiles(string $configFile, string $generatedConfigFile): Configuration
    {
        $config = Yaml::parseFile($configFile);
        $config = array_replace_recursive(Yaml::parseFile($generatedConfigFile), $config);
        $this->loadUsers($config);
        $this->loadHosts($config);
        $this->loadFormatter($config);
        $this->loadLldapProvider($config);
        $this->loadNetwork($config);

        return $this;
    }

    /**
     * @throws NixException
     */
    public function loadFormatter(array $config): void
    {
        if (isset($config['nix']['formatter'])) {
            self::assert(self::TYPE_STRING, $config['nix']['formatter'], 'Bad formatter type');
            $this->formatter = $config['nix']['formatter'];
        }
    }

    public function getFormatter(): string
    {
        return $this->formatter;
    }

    /**
     * @throws NixException
     */
    public function loadLldapProvider(array $config): void
    {
        if (isset($config['hostProvider']['lldap'])) {
            $lldapConfig = $config['hostProvider']['lldap'];
            self::assert(self::TYPE_ARRAY, $lldapConfig, "Bad LLDAP configuration root type");
            self::assert(self::TYPE_STRING, $lldapConfig['url'] ?? null, "A valid lldap url is required", '#^ldap://.+$#');
            self::assert(self::TYPE_STRING, $lldapConfig['bind']['user'] ?? null, "A valid lldap bind user is required", '#^[a-zA-Z][a-zA-Z0-9_-]+$#');
            self::assert(self::TYPE_STRING, $lldapConfig['bind']['passwordFile'] ?? null, "A valid lldap password file is required");
            // $pwdFile = (NIX_PROJECT_ROOT ? NIX_PROJECT_ROOT . '/usr/secrets/' : '') . $lldapConfig['bind']['passwordFile'];
            // if (!file_exists($pwdFile)) {
            //     throw new NixException('LLDAP password file "' . $pwdFile . '" not found.');
            // }
        }
    }

    /**
     * @throws NixException
     */
    public function getLldapConfig(): array
    {
        self::assert(self::TYPE_ARRAY, $this->lldapConfig, "No lldap configuration loaded");
        return $this->lldapConfig;
    }

    /**
     * @throws NixException
     * @todo Auto e-mail by network
     */
    private function loadUsers(array $config): void
    {
        self::assert(self::TYPE_ARRAY, $config['users'] ?? null, "Users not found in configuration");
        $config['users'][self::NIX_USER_NAME] = self::NIX_USER_PARAMS;
        foreach ($config['users'] as $login => $user) {
            self::assert(self::TYPE_STRING, $login, "A user name is required", self::REGEX_LOGIN);
            self::assert(self::TYPE_INT, $user['uid'] ?? '', "A valid uid is required for " . $login);
            self::assert(self::TYPE_STRING, $user['email'] ?? '', "Bad email type for " . $login); // TODO email validation
            self::assert(self::TYPE_STRING, $user['name'] ?? null, "A valid user name is required for " . $login, self::REGEX_NAME);
            self::assert(self::TYPE_STRING, $user['profile'] ?? null, "A valid user profile is required for " . $login, self::REGEX_NAME);
            self::assert(self::TYPE_ARRAY, $user['groups'] ?? [], "Bad user group type for " . $login, null, self::TYPE_STRING);
            $this->users[$login] = (new User())
                ->setUidAndLogin($user['uid'], $login)
                ->setEmail($user['email'] ?? null)
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
        $this->loadStaticHosts($config['hosts']['static'] ?? []);
        $this->loadRangeHosts($config['hosts']['range'] ?? []);
        $this->loadListHosts($config['hosts']['list'] ?? []);
    }

    /**
     * @throws NixException
     */
    private function loadStaticHosts(array $staticHosts): void
    {
        array_map(function (array $host) {
            self::assertHostCommonParams($host);
            self::assertHostName($host['hostname']);
            $this->hosts[$host['hostname']] = (new Host())
                ->setHostname($host['hostname'])
                ->setName($host['name'])
                ->setProfile($host['profile'])
                ->setLocal($host['local'] ?? false)
                ->setArch($host['arch'] ?? null)
                ->setUsers($this->extractAllUsers($host['users'] ?? [], $host['groups'] ?? []))
                ->setGroups($host['groups'] ?? [])
                ->setTags($host['tags'] ?? [])
                ->registerAliases($this->extraNetwork, $host['aliases'] ?? [])
                ->registerInterfaces($this->extraNetwork, $host['interfaces'] ?? [])
                ->registerServices($this->extraNetwork, $host['services'] ?? [])
                ->setIp($this->extraNetwork->getHostIp($host['hostname']));
        }, $staticHosts);
    }

    /**
     * @todo can be optimized
     */
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
        array_map(fn (array $hostGroup) => $this->buildRangeHostGroup($hostGroup), $rangeHosts);
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
                'profile' => $rangeHostGroup['profile'],
                'users' => $rangeHostGroup['users'] ?? [],
                'groups' => $rangeHostGroup['groups'] ?? [],
                'tags' => $rangeHostGroup['tags'] ?? [],
            ];
        }

        foreach ($rangeHostGroup['hosts'] ?? [] as $id => $extraConfig) {
            $hosts[$id] += $extraConfig;
        }

        $this->loadStaticHosts($hosts);
    }

    private function loadListHosts(array $listHosts): void
    {
        array_map(fn (array $hostGroup) => $this->buildListHostGroup($hostGroup), $listHosts);
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
            ]);
        }
        $this->loadStaticHosts($hosts);
    }

    /**
     * @throws NixException
     */
    public function assertHostName(string $hostName): void
    {
        if (array_key_exists($hostName, $this->hosts)) {
            throw new NixException('Host name collision "' . $hostName . '" (value already exists)');
        }
        if (!preg_match(self::REGEX_HOSTNAME, $hostName)) {
            throw new NixException('Invalid host name "' . $hostName . '" (must match ' . self::REGEX_HOSTNAME . ')');
        }
    }

    /**
     * @throws NixException
     */
    public static function assertHostCommonParams(array $host): void
    {
        self::assert(self::TYPE_STRING, $host['hostname'] ?? null, "A hostname is required");
        self::assert(self::TYPE_STRING, $host['name'] ?? null, 'A name (description) is required for "' . $host['hostname'] . '"');
        self::assert(self::TYPE_STRING, $host['profile'] ?? null, 'A host profile is required for "' . $host['hostname'] . '"');
        self::assert(self::TYPE_ARRAY, $host['users'] ?? [], 'Bad users list type for "' . $host['hostname'] . '"', null, self::TYPE_STRING);
        self::assert(self::TYPE_BOOL, $host['local'] ?? false, 'Bad local key type for "' . $host['hostname'] . '"');
    }

    /**
     * @throws NixException
     */
    public static function assert(
        string $type,
        mixed $value,
        string $errMessage,
        ?string $regex = null,
        ?string $subType = null,
        bool $nullableSubType = false
    ): mixed {
        if ($type !== gettype($value)) {
            throw new NixException($errMessage);
        }
        if (!is_null($regex)) {
            if (!is_string($value)) {
                throw new NixException('Cannot check regex with non-string value');
            }
            if (!preg_match($regex, $value)) {
                throw new NixException('Syntax Error for value "' . $value . '": ' . $errMessage);
            }
        }
        if (!is_null($subType)) {
            if ($type !== self::TYPE_ARRAY) {
                throw new NixException('Cannot declare subtype for non-array content');
            }
            array_walk(
                $value,
                fn ($subValue) => ($nullableSubType && is_null($subValue)) || self::assert($subType, $subValue, $errMessage . ' (subvalue type error)')
            );
        }

        return $value;
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
        $this->networkConfig = $this->extraNetwork->registerNetworkConfig($config['network'] ?? [])->getConfig();
        if (isset($this->networkConfig['gateway']['hostname']) && isset($this->networkConfig['gateway']['lan']['ip'])) {
            $gwHost = $this->networkConfig['gateway']['hostname'];
            if (!isset($this->hosts[$gwHost])) {
                throw new NixException('Gateway host "' . $gwHost . '" not found in hosts declarations.');
            }
            $gw = $this->hosts[$gwHost];
            $nip = $this->networkConfig['gateway']['lan']['ip'];
            if (($ip = $gw->getIp()) !== null) {
                if ($ip !== $nip) {
                    throw new NixException('Concurrent gw ip declarations "' . $ip . '" vs "' . $nip . '"');
                }
            } else {
                $gw->setIp($nip);
            }
        }

        return $this;
    }

    public function getNetworkConfig(): array
    {
        return $this->networkConfig + $this->extraNetwork->buildExtraNetworkConfig();
    }
}
