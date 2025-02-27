<?php

namespace Darkone\MdxGenerator;

class Module
{
    private static array $moduleCategories = [
        [
            'title' => 'Macro modules',
            'desc' => '**A macro module** enables a collection of modules and a thematic configuration.',
            'path' => NIX_PROJECT_ROOT . '/dnf/modules/nix/macro',
            'prefix' => 'darkone.',
            'icon' => '&#x1F4E6;',
        ],
        [
            'title' => 'Standard modules',
            'desc' => '**A standard module** enables a feature with one or several packages + a configuration.',
            'path' => NIX_PROJECT_ROOT . '/dnf/modules/nix/core',
            'prefix' => 'darkone.',
            'icon' => '&#x1F48E;',
        ],
        [
            'title' => 'Home Manager modules',
            'desc' => '**A home manager module** works with [home manager](https://github.com/nix-community/home-manager) profiles.',
            'path' => NIX_PROJECT_ROOT . '/dnf/modules/home',
            'prefix' => 'darkone.home.',
            'icon' => '&#x1F3E0;',
        ],
    ];

    /**
     * @throws MdxException
     */
    public static function generateMdx(): string
    {
        return "---
title: Modules
sidebar:
  order: 1
---

import { Tabs, TabItem } from '@astrojs/starlight/components';

" . implode("\n\n", array_map(fn (array $category): string => self::parseModules($category), self::$moduleCategories));
    }

    /**
     * @throws MdxException
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
     * @throws MdxException
     */
    private static function parseAndGenerateMdx(string $filePath, array $category): string
    {
        $fileContent = file_get_contents($filePath);
        $moduleContent = [];
        $moduleContent['comment'] = MdxParser::extractFirstComment($fileContent);
        $moduleContent['path'] = MdxParser::extractModulePath($filePath, $category);
        $moduleContent['options'] = MdxParser::extractModuleOptions($fileContent, $filePath);

        return self::moduleToMd($moduleContent, $category['icon']);
    }

    private static function moduleToMd(array $moduleContent, string $icon): string
    {
        $options = '';
        foreach ($moduleContent['options'] as $option) {
            $options .= '* **' . $option['name'] . '**';
            $options .= $option['default'] ? ' `' . htmlspecialchars($option['default']) . '`' : '';
            $options .= $option['desc'] ? ' ' . htmlspecialchars($option['desc']) : '';
            $options .= "\n";
        }

        return '### ' . $icon . ' ' . $moduleContent['path'] . "\n\n"
        . (is_null($moduleContent['comment']) ? '' : $moduleContent['comment'] . "\n\n") . $options . "\n<hr/>\n\n";
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
            $options .= '|' . htmlspecialchars($option['desc'] ?? '') . "|\n";
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
            $options .= '<TabItem label="' . $option['name'] . '">' . "\n" . htmlspecialchars($option['desc']) . "\n";
            $options .= "```nix\n# Default\n" . $option['default'];
            $options .= $option['example'] ? "\n\n# Example\n" . $option['example'] : '';
            $options .= "\n```\n</TabItem>\n";
        }

        return '### ' . $icon . ' ' . $moduleContent['path'] . "\n\n"
        . (is_null($moduleContent['comment']) ? '' : $moduleContent['comment'] . "\n\n")
        . "<Tabs>\n" . $options . "</Tabs>\n\n";
    }
}
