<?php

namespace Darkone\NixGenerator;

trait ConfigurationAssertTrait
{
    /**
     * @param string $login
     * @param array $user
     * @return void
     * @throws NixException
     */
    public static function assertUserInput(string $login, array $user): void
    {
        self::assert(self::TYPE_STRING, $login, "A user name is required", self::REGEX_LOGIN);
        self::assert(self::TYPE_INT, $user['uid'] ?? '', "A valid uid is required for " . $login);
        self::assert(self::TYPE_EMAIL, $user['email'] ?? '', "Bad email type for " . $login);
        self::assert(self::TYPE_STRING, $user['name'] ?? null, "A valid user name is required for " . $login, self::REGEX_NAME);
        self::assert(self::TYPE_STRING, $user['profile'] ?? null, "A valid user profile is required for " . $login, self::REGEX_NAME);
        self::assert(self::TYPE_ARRAY, $user['groups'] ?? [], "Bad user group type for " . $login, null, self::TYPE_STRING);
    }

    /**
     * @throws NixException
     */
    public function assertHostName(string $hostName): void
    {
        if (!preg_match(self::REGEX_HOSTNAME, $hostName)) {
            throw new NixException('Invalid host name "' . $hostName . '" (must match ' . self::REGEX_HOSTNAME . ').');
        }
        if (array_key_exists($hostName, $this->hosts ?? [])) {
            throw new NixException('Host name collision "' . $hostName . '" (value already exists).');
        }
        if (isset($this->zones[$hostName])) {
            throw new NixException('Name "' . $hostName . '" cannot be used for a host because it is a name of a zone.');
        }
        if (in_array($hostName, [
            'common',
            self::EXTERNAL_ZONE_KEY,
            $this->network->getCoordinationDomainName()
        ])) {
            throw new NixException('Name "' . $hostName . '" cannot be used for a host because this word is reserved.');
        }
    }

    // TODO: To check:
    // - Check IPs formats? : 2.x, 3.x for static, etc.

    /**
     * @throws NixException
     */
    public function assertHostInput(array $host): void
    {
        self::assert(self::TYPE_STRING, $host['hostname'] ?? null, "A hostname is required");
        self::assert(self::TYPE_STRING, $host['name'] ?? null, 'A name (description) is required for "' . $host['hostname'] . '"');
        self::assert(self::TYPE_STRING, $host['profile'] ?? null, 'A host profile is required for "' . $host['hostname'] . '"');
        self::assert(self::TYPE_ARRAY, $host['users'] ?? [], 'Bad users list type for "' . $host['hostname'] . '"', null, self::TYPE_STRING);
        self::assert(self::TYPE_ARRAY, $host['disko'] ?? [], 'Bad disko params');
        self::assert(self::TYPE_BOOL, $host['local'] ?? false, 'Bad local key type for "' . $host['hostname'] . '"');
        self::assert(self::TYPE_STRING, $host['zone'] ?? $host['ipv4']['external'] ?? null, 'A zone name or ipv4 is required for "' . $host['hostname'] . '"');
        isset($host['ipv4']['internal']) && self::assert(self::TYPE_STRING, $host['ipv4']['internal'], 'Bad syntax for internal ipv4 of "' . $host['hostname'] . '"', self::REGEX_IPV4_TAILNET);
        isset($host['ipv4']['external']) && self::assert(self::TYPE_STRING, $host['ipv4']['external'], 'Bad syntax for external ipv4 of "' . $host['hostname'] . '"', self::REGEX_IPV4);
        $this->checkZoneField($host);
        $this->checkHostMacAddress($host);
    }

    /**
     * @param array $host
     * @throws NixException
     */
    public function checkZoneField(array $host): void
    {
        // External zone
        if (!empty($host['ipv4'])) {
            if (!empty($host['zone'])) {
                throw new NixException('A host "' . $host['hostname'] . '" in a local zone cannot have an ipv4 key.');
            }
            return;
        }
        [$zone, $ipSuffix] = explode(':', $host['zone'] . ':');
        if ($zone === 'common') {
            throw new NixException('A host (' . $host['hostname'] . ') cannot have a "common" zone.');
        }
        if (!isset($this->config['zones'][$zone])) {
            throw new NixException('Unknown zone "' . $zone . '" of host "' . $host['hostname'] . '".');
        }
        if (!empty($ipSuffix) && !preg_match('/^([0-9]{1,3}\.)?[0-9]{1,3}$/', $ipSuffix)) {
            throw new NixException('Bad ip suffix syntax "' . $ipSuffix . '" for the host "' . $host['hostname'] . '".');
        }
    }

    /**
     * @param array $host
     * @return void
     * @throws NixException
     */
    public function checkHostMacAddress(array $host): void
    {
        $zoneField = explode(':', $host['zone'] ?? '');
        $isGateway = isset($zoneField[1]) && $zoneField[1] == '1.1';
        if (!empty($host['ipv4']) && !empty($host['mac'])) {
            throw new NixException('External host "' . $host['hostname'] . '" mac address is useless.');
        }
        if (!empty($host['ipv4']) && !empty($host['zone'])) {
            throw new NixException('External host "' . $host['hostname'] . '" cannot have a zone.');
        }
        if ($isGateway && !empty($host['mac'])) {
            throw new NixException('Gateway "' . $host['hostname'] . '" mac address is useless.');
        }
        if (count($zoneField) > 1 && !$isGateway && empty($host['mac'])) {
            throw new NixException('Host "' . $host['hostname'] . '" must have a mac address with its ip address.');
        }
    }

    /**
     * @param string $ip
     * @return void
     * @throws NixException
     */
    public static function assertTailscaleIp(string $ip): void
    {
        // Is IPv4
        if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
            throw new NixException('ipv4 "' . $ip . '" is not a valid address.');
        }

        $longIp = ip2long($ip);

        // 100.64.0.0/10 = from 100.64.0.0 to 100.127.255.255
        if ($longIp < ip2long('100.64.0.1') || $longIp > ip2long('100.127.255.254')) {
            throw new NixException('ipv4 "' . $ip . '" is not a tailnet address (100.64.0.0/10).');
        }
    }

    /**
     * @param string $name
     * @param string $context
     * @param string|null $namespace
     * @return void
     * @throws NixException
     */
    public static function assertUniqName(string $name, string $context, ?string $namespace = null): void
    {
        static $names = [];
        static $namesWithNs = [];

        if (isset($names[$name])) {
            throw new NixException('Name "' . $name . '" already exists (' . $context . ' vs ' . $names[$name] . ')');
        }
        if ($namespace !== null) {
            if (isset($namesWithNs[$namespace][$name])) {
                throw new NixException(
                    'Name "' . $namespace . '::' . $name . '" already exists ('
                    . $context . ' vs ' . $namesWithNs[$namespace][$name] . ')'
                );
            }
            $namesWithNs[$namespace][$name] = $context;
        } else {
            $names[$name] = $context;
        }
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
        if ($type === self::TYPE_EMAIL) {
            if (!is_string($value) || (!empty($value) && !filter_var($value, FILTER_VALIDATE_EMAIL))) {
                throw new NixException('Email "' . $value . '": ' . $errMessage);
            }
        } elseif ($type !== gettype($value)) {
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
}
