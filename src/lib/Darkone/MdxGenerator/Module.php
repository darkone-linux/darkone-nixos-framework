<?php

namespace Darkone\MdxGenerator;

use Darkone\NixGenerator\NixException;

class Module
{
    private static array $moduleCategories = [
        [
            'title' => 'Mixin modules',
            'desc' => '**A mixin module** defines a collection of standard modules with a consistent common configuration.',
            'path' => NIX_PROJECT_ROOT . '/dnf/modules/mixin',
            'prefix' => 'darkone.',
            'icon' => '&#x1F4E6;',
        ],
        [
            'title' => 'Standard modules',
            'desc' => '**A standard module** contains auto-configured features.',
            'path' => NIX_PROJECT_ROOT . '/dnf/modules/standard',
            'prefix' => 'darkone.',
            'icon' => '&#x1F48E;',
        ],
        [
            'title' => 'Home Manager modules',
            'desc' => '**A home manager module** works with [home manager](https://github.com/nix-community/home-manager) profiles.',
            'path' => NIX_PROJECT_ROOT . '/dnf/home/modules',
            'prefix' => 'darkone.home.',
            'icon' => '&#x1F3E0;',
        ],
    ];

    /**
     * @return string
     * @throws NixException
     */
    public static function generateMdx(): string
    {
        return "---
title: Modules
sidebar:
  order: 1
  badge:
    text: New
    variant: tip
---

" . implode("\n\n", array_map(fn (array $category): string => self::parseModules($category), self::$moduleCategories));
    }

    /**
     * @param array $category
     * @return string
     * @throws NixException
     */
    private static function parseModules(array $category): string
    {
        $mdx = '## ' . $category['title'] . "\n\n";
        $mdx .= ":::note\n" . $category['desc'] . "\n:::\n\n";
        foreach (MdxParser::extractNixFiles($category['path']) as $filePath) {
            $mdx .= self::parseAndGenerateMdx($filePath, $category);
        }

        return $mdx;
    }

    /**
     * @param string $filePath
     * @param array $category
     * @return string
     * @throws NixException
     */
    private static function parseAndGenerateMdx(string $filePath, array $category): string
    {
        $fileContent = file_get_contents($filePath);
        $moduleContent = [];
        $moduleContent['comment'] = MdxParser::extractFirstComment($fileContent);
        $moduleContent['path'] = MdxParser::extractModulePath($filePath, $category);
        $moduleContent['options'] = MdxParser::extractModuleOptions($fileContent, $filePath);
        #print_r($moduleContent['options']);

        return self::moduleToMd($moduleContent, $category['icon']);
    }

    /**
     * @param array $moduleContent
     * @param string $icon
     * @return string
     */
    private static function moduleToMd(array $moduleContent, string $icon): string
    {
        $options = '';
        $optionCount = count($moduleContent['options']);
        $code = "\n```nix\n" . ($optionCount > 1 ? $moduleContent['path'] . " = {\n" : "");
        $prefix = $optionCount > 1 ? '  ' : $moduleContent['path'] . '.';
        $openedLevels = [];
        $lastLevel = 1;
        $namesByLevel = [];
        foreach ($moduleContent['options'] as $i => $option) {
            if ($option['level'] > $lastLevel) {
                $openedLevels[$lastLevel] = $namesByLevel[$lastLevel] . '.';
            } else {
                unset($openedLevels[$lastLevel]);
            }
            $lastLevel = $option['level'];
            $namesByLevel[$option['level']] = $option['name'];
            $levelSpaces = str_repeat('  ', $option['level'] - 1);
            $options .= $levelSpaces . '* **' . htmlentities($option['name']) . '**';
            $options .= $option['type'] ? ' `' . $option['type'] . '`' : '';
            $options .= $option['description'] ? ' ' . htmlspecialchars(trim($option['description'], ' "')) : '';
            $options .= "\n";

            $codeValue = empty($option['example']) ? $option['default'] : $option['example'];

            if ($codeValue == '{ }' && isset($moduleContent['options'][$i + 1]) && $moduleContent['options'][$i + 1]['level'] > $lastLevel) {
                continue;
            }

            $code .= $prefix . implode('', $openedLevels) . $option['name'] . ' = ' . $codeValue . ';' . "\n";
        }
        $code .= ($optionCount > 1 ? "};\n" : "") . "```\n\n";

        return '### ' . $icon . ' ' . $moduleContent['path'] . "\n\n"
        . (is_null($moduleContent['comment']) ? '' : $moduleContent['comment'] . "\n\n") . $options . $code . "<hr/>\n\n";
    }

    /**
     * Table alternative, less lisible
     */
    private static function moduleToMdTable(array $moduleContent, string $icon): string
    {
        $options = "|Option|Default|Description|\n|:-:|:-:|:-|\n";
        foreach ($moduleContent['options'] as $option) {
            $options .= '|`' . $option['name'] . '`';
            $options .= '|`' . htmlspecialchars($option['default'] ?? '') . '`';
            $options .= '|' . htmlspecialchars($option['description'] ?? '') . "|\n";
        }

        return '### ' . $icon . ' ' . $moduleContent['path'] . "\n\n"
        . (is_null($moduleContent['comment']) ? '' : $moduleContent['comment'] . "\n\n") . $options . "\n";
    }

    /**
     * Alternative for future
     */
    private static function moduleToMdx(array $moduleContent, string $icon): string
    {
        $options = '';
        foreach ($moduleContent['options'] as $option) {
            $options .= '<TabItem label="' . $option['name'] . '">' . "\n" . htmlspecialchars($option['description']) . "\n";
            $options .= "```nix\n# Default\n" . $option['default'];
            $options .= $option['example'] ? "\n\n# Example\n" . $option['example'] : '';
            $options .= "\n```\n</TabItem>\n";
        }

        return '### ' . $icon . ' ' . $moduleContent['path'] . "\n\n"
        . (is_null($moduleContent['comment']) ? '' : $moduleContent['comment'] . "\n\n")
        . "<Tabs>\n" . $options . "</Tabs>\n\n";
    }
}
