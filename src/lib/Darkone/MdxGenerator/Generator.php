<?php

namespace Darkone\MdxGenerator;

use Darkone\NixGenerator\NixException;

class Generator
{
    /**
     * @param bool $debug
     * @return string
     * @throws NixException
     */
    public static function generateAll(bool $debug): string
    {
        if ($debug) {
            return Module::generateMdx();
        }

        file_put_contents(
            NIX_PROJECT_ROOT . '/doc/src/content/docs/ref/modules.mdx',
            Module::generateMdx()
        );

        return '';
    }
}
