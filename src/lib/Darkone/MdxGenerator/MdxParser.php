<?php

namespace Darkone\MdxGenerator;

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
        return array_key_exists(1, $matches) ? preg_replace('/^# */m', '', $matches[1]) : null;
    }

    public static function extractModulePath(string $filePath, array $category): string
    {
        return $category['prefix'] . strtr(preg_replace('#' . $category['path'] . '/(.+)\.nix$#s', '$1', $filePath), '/', '.');
    }

    /**
     * @throws MdxException
     */
    public static function extractModuleOptions(string $fileContent, string $filePath): array
    {
        $options = [];

        // mkEnableOption
        preg_match_all('/([a-zA-Z0-9_-]+) *=[^\n]*mkEnableOption +"([^\n]+)"; *\n/s', $fileContent, $matches);
        for ($i = 0; $i < count($matches[0]); $i++) {
            $options[] = [
                'name' => $matches[1][$i],
                'type' => 'bool',
                'default' => 'false',
                'desc' => $matches[2][$i],
                'example' => null,
            ];
        }

        // mkOption
        preg_match_all('/([a-zA-Z0-9_-]+) *=[^\n]*mkOption +{(.+?)\n +}; *\n/s', $fileContent, $matches);
        for ($i = 0; $i < count($matches[0]); $i++) {
            preg_match('/^.*type = [a-z.]*?([a-z]+);.*$/s', $matches[2][$i], $typeMatches);
            preg_match('/^.*default = ([^\n]+?);\n.*$/s', $matches[2][$i], $defaultMatches);
            preg_match('/^.*example = "?([^"]+?)"?;.*$/s', $matches[2][$i], $exampleMatches);
            preg_match('/^.*description = "([^"]+)";.*$/s', $matches[2][$i], $descMatches);
            $options[] = [
                'name' => $matches[1][$i],
                'type' => $typeMatches[1] ?? '?',
                'default' => $defaultMatches[1] ?? null,
                'desc' => $descMatches[1] ?? null,
                'example' => $exampleMatches[1] ?? null,
            ];
        }

        if (empty($options)) {
            throw new MdxException('No option found in module ' . $filePath);
        }

        return $options;
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
