<?php

namespace Darkone;

use Darkone\MdxGenerator\Generator;
use Darkone\NixGenerator\Configuration;
use Darkone\NixGenerator\Item\Host;
use Darkone\NixGenerator\NixBuilder;
use Darkone\NixGenerator\NixException;
use Darkone\NixGenerator\Token\NixAttrSet;
use Darkone\NixGenerator\Token\NixList;
use UnhandledMatchError;

class Generate
{
    private Configuration $config;

    /**
     * @throws NixException
     */
    public function __construct(string $yamlConfigFile, string $yamlGeneratedConfigFile)
    {
        if (!defined('NIX_PROJECT_ROOT')) {
            throw new NixException('NIX_PROJECT_ROOT must be defined');
        }
        $this->config = (new Configuration())->loadYamlFiles($yamlConfigFile, $yamlGeneratedConfigFile);
    }

    /**
     * @throws NixException
     */
    public function generate(string $what): string
    {
        try {
            return match ($what) {
                'hosts' => $this->generateHosts(),
                'users' => $this->generateUsers(),
                'network' => $this->generateNetworkConfig(),
                'disko' => $this->generateDisko(),
                'doc' => $this->generateDoc()
            };
        } catch (UnhandledMatchError) {
            throw new NixException('Unknown item "' . $what . '", unable to generate');
        }
    }

    /**
     * Generate the hosts.nix file loaded by flake.nix
     * @throws NixException
     */
    private function generateHosts(): string
    {
        $hosts = new NixList();
        foreach ($this->config->getHosts() as $host) {
            $deployment = (new NixAttrSet())
                ->set('tags', (new NixList())->populateStrings($this->extractTags($host)));
            $colmena = (new NixAttrSet())->set('deployment', $deployment);
            $newHost = (new NixAttrSet())
                ->setString('hostname', $host->getHostname())
                ->setString('name', $host->getName())
                ->setString('profile', $host->getProfile())
                ->setString('ip', $host->getIp())
                ->setString('arch', $host->getArch())
                ->set('groups', (new NixList())->populateStrings($host->getGroups()))
                ->set('users', (new NixList())->populateStrings($host->getUsers()))
                ->set('colmena', $colmena)
                ->set('services', NixBuilder::arrayToNix($host->getServices()));
            $hosts->add($newHost);
        }

        return $hosts;
    }

    /**
     * Generate the hosts.nix file loaded by flake.nix
     * @throws NixException
     */
    private function generateUsers(): string
    {
        $users = new NixAttrSet();
        foreach ($this->config->getUsers() as $user) {
            $users->set($user->getLogin(), (new NixAttrSet())
                ->setInt('uid', $user->getUid())
                ->setString('email', $user->getEmail())
                ->setString('name', $user->getName())
                ->setString('profile', $user->getProfile())
                ->set('groups', (new NixList())->populateStrings($user->getGroups())));
        }

        return $users;
    }

    private function extractTags(Host $host): array
    {
        return array_merge(
            $host->getTags(),
            array_map(fn (string $group): string => 'group-' . $group, $host->getGroups()),
            array_map(fn (string $user): string => 'user-' . $user, array_filter($host->getUsers(), fn (string $user): bool => $user !== 'nix'))
        );
    }

    /**
     * Generate the hosts.nix file loaded by flake.nix
     * @throws NixException
     */
    private function generateNetworkConfig(): string
    {
        return (string) NixBuilder::arrayToNix($this->config->getNetworkConfig());
    }

    /**
     * Generate and write host disko profiles
     * @throws NixException
     */
    private function generateDisko(): string
    {
        $stream = '';
        foreach ($this->config->getHosts() as $host) {
            $disko = $host->getDisko();
            if (empty($disko['profile'])) {
                $stream .= $host->getHostname() . " {}\n";
                continue;
            }
            $fileContent = '{lib,...}:{imports=[' . $disko['profile'] . '];';
            foreach ($disko['devices'] ?? [] as $name => $device) {
                $fileContent .= 'disko.devices.disk.' . $name . '.device=lib.mkForce "' . $device . '";';
            }
            $stream .= $host->getHostname() . ' ' . $fileContent . "}\n";
        }
        return $stream;
    }

    private function generateDoc(): string
    {
        Generator::generateAll();
        return '';
    }
}
