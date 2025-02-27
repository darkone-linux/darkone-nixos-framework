<?php

namespace Darkone\NixGenerator\Token;

use ArrayIterator;
use Darkone\NixGenerator\NixException;
use Iterator;

/**
 * Nix Attribute Set
 */
class NixAttrSet implements NixItemInterface, Iterator
{
    /**
     * @var $attrSet ArrayIterator
     */
    private ArrayIterator $attrSet;

    public function __construct()
    {
        $this->attrSet = new ArrayIterator();
    }

    public function set(string $key, NixItemInterface $value): NixAttrSet
    {
        $this->attrSet[$key] = $value;
        return $this;
    }

    /**
     * @throws NixException
     */
    public function setInt(string $key, int|string|float|bool $value): NixAttrSet
    {
        return $this->set($key, (new NixValue($value))->forceInt());
    }

    /**
     * @throws NixException
     */
    public function setFloat(string $key, int|string|float|bool $value): NixAttrSet
    {
        return $this->set($key, (new NixValue($value))->forceFloat());
    }

    /**
     * @throws NixException
     */
    public function setString(string $key, null|int|string|float|bool $value): NixAttrSet
    {
        if (is_null($value)) {
            return $this;
        }
        return $this->set($key, (new NixValue($value))->forceString());
    }

    /**
     * @throws NixException
     */
    public function setBool(string $key, int|string|float|bool $value): NixAttrSet
    {
        return $this->set($key, (new NixValue($value))->forceBool());
    }

    public function __toString(): string
    {
        $retVal = '';
        foreach ($this->attrSet as $key => $value) {

            // Complex keys (for example ip addresses)
            if (!preg_match('/^[a-zA-Z0-9_-]+$/', $key)) {
                $key = '"' . $key . '"';
            }
            $retVal .= $key . '=' . $value . ';';
        }

        return '{' . $retVal . '}';
    }

    /**
     * Return the current element
     * @link https://php.net/manual/en/iterator.current.php
     */
    public function current(): NixItemInterface
    {
        return $this->attrSet->current();
    }

    /**
     * Move forward to next element
     * @link https://php.net/manual/en/iterator.next.php
     */
    public function next(): void
    {
        $this->attrSet->next();
    }

    /**
     * Return the key of the current element
     * @link https://php.net/manual/en/iterator.key.php
     */
    public function key(): string
    {
        return $this->attrSet->key();
    }

    /**
     * Checks if current position is valid
     * @link https://php.net/manual/en/iterator.valid.php
     * @return bool The return value will be casted to boolean and then evaluated.
     * Returns true on success or false on failure.
     */
    public function valid(): bool
    {
        return $this->attrSet->valid();
    }

    /**
     * Rewind the Iterator to the first element
     * @link https://php.net/manual/en/iterator.rewind.php
     * @return void Any returned value is ignored.
     */
    public function rewind(): void
    {
        $this->attrSet->rewind();
    }
}
