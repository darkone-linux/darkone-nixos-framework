<?php

namespace Darkone\MdxGenerator;

class Generator
{
    public static function generateAll(): void
    {
        file_put_contents(
            NIX_PROJECT_ROOT . '/doc/src/content/docs/ref/modules.mdx',
            Module::generateMdx()
        );
    }
}
