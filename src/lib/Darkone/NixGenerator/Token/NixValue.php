<?php

namespace Darkone\NixGenerator\Token;

use Darkone\NixGenerator\NixException;

/**
 * Nix elementary value
 */
class NixValue implements NixItemInterface
{
    private mixed $value = null;

    /**
     * @throws NixException
     */
    public function __construct(mixed $value)
    {
        if (is_int($value) || is_bool($value) || is_float($value) || is_string($value) || $value instanceof NixItemInterface) {
            $this->value = $value;
        } else {
            throw new NixException('Value type ' . gettype($value) . ' is not allowed for an elementary nix value.');
        }
    }

    public function forceInt(): NixValue
    {
        $this->value = (int) $this->value;
        return $this;
    }

    public function forceFloat(): NixValue
    {
        $this->value = (float) $this->value;
        return $this;
    }

    public function forceString(): NixValue
    {
        $this->value = (string) $this->value;
        return $this;
    }

    public function forceBool(): NixValue
    {
        $this->value = (bool) $this->value;
        return $this;
    }

    public function __toString(): string
    {
        return match (true) {
            is_string($this->value) => '"' . str_replace('"', '\"', $this->value) . '"',
            is_bool($this->value) => $this->value ? 'true' : 'false',
            default => $this->value,
        };
    }
}
