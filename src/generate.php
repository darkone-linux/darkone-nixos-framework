<?php

use Darkone\Generate;
use Darkone\NixGenerator\NixException;

define('NIX_PROJECT_ROOT', realpath(__DIR__ . '/..'));

require __DIR__ . '/vendor/autoload.php';

$debug = ($_SERVER['argv'][2] ?? '') == 'debug';

try {
    $generator = new Generate(
        __DIR__ . '/../usr/config.yaml',
        __DIR__ . '/../var/generated/config.yaml'
    );
    echo $generator->generate($_SERVER['argv'][1] ?? '?', $debug);
} catch (NixException $e) {
    echo "ERR: " . $e->getMessage() . PHP_EOL;
    echo $debug ? $e->getTraceAsString() : '';
    die(1);
}
