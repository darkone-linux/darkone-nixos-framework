<?php

namespace Darkone\NixGenerator;

use Darkone\NixGenerator\Item\Host;
use Darkone\NixGenerator\Item\User;
use Darkone\NixGenerator\Token\NixAttrSet;
use Symfony\Component\Yaml\Yaml;

class Configuration extends NixAttrSet
{
    const TYPE_STRING = 'string';
    const TYPE_BOOL = 'bool';
    const TYPE_ARRAY = 'array';
    const TYPE_INT = 'int';

    const MAX_RANGE_BOUND = 1000;

    const REGEX_HOSTNAME = '/^[a-zA-Z][a-zA-Z0-9_-]{2,59}$/';
    const REGEX_LOGIN = '/^[a-zA-Z][a-zA-Z0-9_-]{2,59}$/';
    const REGEX_NAME = '/^.{3,128}$/';

    const DEFAULT_NETWORK_DOMAIN = 'darkone.lan';
    const DEFAULT_PROFILE = 'minimal';

    private string $formatter = 'nixfmt';
    private array|null $lldapConfig = null;

    /**
     * @var User[]
     */
    private array $users = [];

    /**
     * @var Host[]
     */
    private array $hosts = [];

    /**
     * Load nix configuration
     * @throws NixException
     */
    public function loadYamlFile(string $configFile): Configuration
    {
        $config = Yaml::parseFile($configFile);
        $this->loadUsers($config);
        $this->loadHosts($config);
        $this->loadFormatter($config);
        $this->loadLldapProvider($config);
        return $this;
    }

    /**
     * @throws NixException
     */
    public function loadFormatter(array $config): void
    {
        if (isset($config['nix']['formatter'])) {
            $this->assert(self::TYPE_STRING, $config['nix']['formatter'], 'Bad formatter type');
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
            $this->assert(self::TYPE_ARRAY, $lldapConfig, "Bad LLDAP configuration root type");
            $this->assert(self::TYPE_STRING, $lldapConfig['url'] ?? null, "A valid lldap url is required", '#^ldap://.+$#');
            $this->assert(self::TYPE_STRING, $lldapConfig['bind']['user'] ?? null, "A valid lldap bind user is required", '#^[a-zA-Z][a-zA-Z0-9_-]+$#');
            $this->assert(self::TYPE_STRING, $lldapConfig['bind']['passwordFile'] ?? null, "A valid lldap password file is required");
            $pwdFile = (NIX_PROJECT_ROOT ? NIX_PROJECT_ROOT . '/' : '') . $lldapConfig['bind']['passwordFile'];
            if (!file_exists($pwdFile)) {
                throw new NixException('Lldap password file "' . $pwdFile . '" not found.');
            }
        }
    }

    /**
     * @throws NixException
     */
    public function getLldapConfig(): array
    {
        $this->assert(self::TYPE_ARRAY, $this->lldapConfig, "No lldap configuration loaded");
        return $this->lldapConfig;
    }

    /**
     * @throws NixException
     */
    private function loadUsers(array $config): void
    {
        $this->assert(self::TYPE_ARRAY, $config['users'] ?? null, "Users not found in configuration");
        foreach ($config['users'] as $login => $user) {
            $this->assert(self::TYPE_STRING, $login, "A user name is required", self::REGEX_LOGIN);
            $this->assert(self::TYPE_STRING, $user['email'] ?? '', "Bad email type for " . $login); // TODO email validation
            $this->assert(self::TYPE_STRING, $user['name'] ?? null, "A valid user name is required for " . $login, self::REGEX_NAME);
            $this->assert(self::TYPE_STRING, $user['profile'] ?? null, "A valid user profile is required for " . $login, self::REGEX_NAME);
            $this->assert(self::TYPE_ARRAY, $user['groups'] ?? [], "Bad user group type for " . $login);
            $this->users[$login] = (new User())
                ->setLogin($login)
                ->setEmail($user['email'] ?? $login . '@' . ($config['network']['domain'] ?? self::DEFAULT_NETWORK_DOMAIN))
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
        $this->assert(self::TYPE_ARRAY, $config['hosts'], "Bad hosts root value");
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
            $this->assertHostCommonParams($host);
            $this->assertHostName($host['hostname']);
            $this->hosts[$host['hostname']] = (new Host())
                ->setHostname($host['hostname'])
                ->setName($host['name'])
                ->setUsers($this->getAllUsers($host['users'], $host['groups']))
                ->setGroups($host['groups']);
        }, $staticHosts);
    }

    /**
     * @todo can be optimized
     */
    private function getAllUsers(array $users, array $groups): array
    {
        foreach ($groups as $group) {
            foreach ($this->getUsers() as $user) {
                if (!isset($users[$user->getLogin()]) && in_array($group, $user->getGroups())) {
                    $users[] = $user->getLogin();
                }
            }
        }

        return $users;
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
        $range = $this->assert(self::TYPE_ARRAY, $rangeHostGroup['range'], "Bad range type");
        if (count($range) !== 2 || !is_int($range[0]) || !is_int($range[1])) {
            throw new NixException('Bad range [' . $range[0] . ', ' . $range[0] . ']');
        }
        $count = $range[1] - $range[0];
        if ($count < 0 || $count > self::MAX_RANGE_BOUND) {
            throw new NixException('Range [' . $range[0] . ', ' . $range[0] . '] out of bound');
        }

        $hosts = [];
        for ($i = $range[0]; $i <= $range[1]; $i++) {
            $hosts[] = [
                'hostname' => sprintf($rangeHostGroup['hostname'], $i),
                'name' => sprintf($rangeHostGroup['name'], $i),
                'users' => $rangeHostGroup['users'] ?? [],
                'groups' => $rangeHostGroup['groups'] ?? [],
            ];
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
        $list = $this->assert(self::TYPE_ARRAY, $listHostGroup['hosts'], "Bad hosts list type");
        $hosts = [];
        foreach ($list as $hostname => $hostdesc) {
            $this->assert(self::TYPE_STRING, $hostname, "Bad host name (hostname key)", self::REGEX_HOSTNAME);
            $this->assert(self::TYPE_STRING, $hostdesc, "Bad host description (name)", self::REGEX_NAME);
            $hosts[] = [
                'hostname' => sprintf($listHostGroup['hostname'] ?? "%s", $hostname),
                'name' => sprintf($listHostGroup['name'] ?? "%s", $hostdesc),
                'users' => $listHostGroup['users'] ?? [],
                'groups' => $listHostGroup['groups'] ?? [],
            ];
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
    public function assertHostCommonParams(array $host): void
    {
        $this->assert(self::TYPE_STRING, $host['hostname'] ?? null, "A hostname is required");
        $this->assert(self::TYPE_STRING, $host['name'] ?? null, "A name (description) is required");
        $this->assert(self::TYPE_ARRAY, $host['users'] ?? null, "A list of users is required");
    }

    /**
     * @throws NixException
     */
    public function assert(string $type, mixed $value, string $errMessage, ?string $regex = null): mixed
    {
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
}
