<?php

use Darkone\Generate;
use Darkone\NixGenerator\NixException;

define('NIX_PROJECT_ROOT', realpath(__DIR__ . '/..'));

require __DIR__ . '/vendor/autoload.php';

try {
    $generator = new Generate(__DIR__ . '/../usr/config.yaml');
    echo $generator->generate($_SERVER['argv'][1] ?? '?');
} catch (NixException $e) {
    trigger_error("ERR: " . $e->getMessage(), E_USER_ERROR);
}
