<?php

namespace Darkone\MdxGenerator;

use Darkone\NixGenerator\NixException;
use InvalidArgumentException;
use RecursiveDirectoryIterator;
use RecursiveIteratorIterator;
use RegexIterator;

/**
 * @todo use a real nix parser
 */
class MdxParser
{
    public static function extractFirstComment(string $fileContent): ?string
    {
        preg_match('/^(#.+?)\n[^#].*$/s', $fileContent, $matches);
        return array_key_exists(1, $matches) ? preg_replace('/^# ?/m', '', $matches[1]) : null;
    }

    public static function extractModulePath(string $filePath, array $category): string
    {
        return $category['prefix'] . strtr(preg_replace('#' . $category['path'] . '/(.+)\.nix$#s', '$1', $filePath), '/', '.');
    }

    /**
     * TODO: Ce parseur initial nécessite une écriture spécifique des options. Remplacer par un vrai parseur nix.
     * @param string $fileContent
     * @param string $filePath
     * @return array
     * @throws NixException
     */
    public static function extractModuleOptions(string $fileContent, string $filePath): array
    {
        $options = [];
        $lines = explode("\n", trim($fileContent));

        $currOpt = [];
        $levels = [];
        $inOpt = false;
        $prefix = '';
        foreach ($lines as $line) {
            if (preg_match('/^( *)(' . $prefix . ')?([a-zA-Z0-9._-]+) *=[^\n]*mkEnableOption +"([^\n]+)";$/', $line, $matches)) {
                if (empty($prefix)) {
                    $prefix = preg_replace('/^(.+\.)[^.]+/', '$1', $matches[3]);
                    $matches[3] = substr($matches[3], strlen($prefix));
                }
                if (!empty($currOpt)) {
                    $options[] = $currOpt;
                    $currOpt = [];
                }
                $options[] = array_filter([
                    'level' => self::extractLevel($levels, strlen($matches[1]), $filePath),
                    'name' => $matches[3],
                    'type' => 'bool',
                    'default' => 'false',
                    'description' => $matches[4],
                    'example' => null,
                ]);
                $inOpt = false;
            }
            if (preg_match('/^( +)(' . $prefix . ')?([a-zA-Z0-9._-]+) *=[^\n]*mkOption +{$/', $line, $matches)) {
                if (empty($prefix)) {
                    $prefix = preg_replace('/^(.+\.)[^.]+/', '$1', $matches[3]);
                    $matches[3] = substr($matches[3], strlen($prefix));
                }
                if (!empty($currOpt)) {
                    $options[] = $currOpt;
                }
                $currOpt = [
                    'level' => self::extractLevel($levels, strlen($matches[1]), $filePath),
                    'name' => $matches[3],
                    'default' => null,
                ];
                $inOpt = true;
            }
            if (trim($line) == '};') {
                if (!empty($currOpt)) {
                    $options[] = $currOpt;
                    $currOpt = [];
                }
                $inOpt = false;
            }
            if ($inOpt && preg_match('/^ +(type|default|example|description) = (.*?);?$/s', $line, $matches)) {
                $currOpt[$matches[1]] = preg_replace('/(lib\.)?types\./', '', $matches[2]);
            }
        }
        if (!empty($currOpt)) {
            $options[] = $currOpt;
        }

        $lastLevel = 0;
        foreach ($options as &$option) {
            if (($option['level'] - $lastLevel) > 1) {
                throw new NixException('Option level gap ' . $option['level'] . '-' . $lastLevel . ' too high for ' . $filePath);
            }
            if (!isset($option['type'])) {
                throw new NixException('No type for option ' . $option['name'] . ' in ' . $filePath);
            }
            if (str_starts_with($option['type'], 'list')) {
                $option['default'] = '[ ]';
                unset($option['example']);
            }
            if (str_starts_with($option['type'], 'attrs')) {
                $option['type'] = 'attrs';
                $option['default'] = '{ }';
                unset($option['example']);
            }
            if (str_starts_with($option['type'], 'submodule')) {
                $option['type'] = 'submodule';
                $option['default'] = '{ }';
                unset($option['example']);
            }
            if (str_starts_with($option['type'], 'lines')) {
                $option['type'] = 'lines';
                $option['default'] = '""';
                unset($option['example']);
            }
            if (preg_match('/^.* (<[a-zA-Z]+>)$/', $option['description'], $matches)) {
                $option['name'] .= '.' . $matches[1];
            }
            $lastLevel = $option['level'];
        }

        return $options;
    }

    /**
     * @param array $levels
     * @param int $spaces
     * @param string $filePath
     * @return int
     * @throws NixException
     */
    private static function extractLevel(array &$levels, int $spaces, string $filePath): int
    {
        if (empty($levels)) {
            $levels[$spaces] = 1;
        }
        if ($spaces > max(array_keys($levels))) {
            $levels[$spaces] = count($levels) + 1;
        }
        if (isset($levels[$spaces])) {
            return $levels[$spaces];
        }
        print_r($levels);
        print_r($spaces);
        throw new NixException('Ambiguous option level in ' . $filePath);
    }

    public static function extractNixFiles(string $directory): array
    {
        is_dir($directory) || throw new InvalidArgumentException('Directory "' . $directory . '" not found.');
        $directoryIterator = new RecursiveDirectoryIterator($directory);
        $recursiveIterator = new RecursiveIteratorIterator($directoryIterator);
        $regexIterator = new RegexIterator($recursiveIterator, '#^' . $directory . '.+\.nix$#i', RegexIterator::GET_MATCH);
        $files = array_map(fn (array $fileInfo): string => (string) $fileInfo[0], iterator_to_array($regexIterator));
        $files = array_filter($files, fn (string $file): bool => ! preg_match('/^.*\/default\.nix$/', trim($file)));
        sort($files);

        return $files;
    }
}
