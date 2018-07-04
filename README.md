# Pipes-Concurrency v2.0.11

`pipes-concurrency` provides an actor-like concurrency system that interfaces
with
[the `pipes` library](https://github.com/Gabriel439/Haskell-Pipes-Library).

## Quick start

* Install the [Haskell Platform](http://www.haskell.org/platform/)
* `cabal install pipes-concurrency`

The official tutorial is on
[Hackage](http://hackage.haskell.org/package/pipes-concurrency).

## Features

* *Simple API*: Use only five functions

* *Deadlock Safety*: Automatically avoid concurrency deadlocks

* *Flexibility*: Build many-to-many and cyclic communication topologies

* *Dynamic Graphs*: Add or remove readers and writers at any time

## Outline

`pipes-concurrency` just really, really useful for concurrency, even if you
don't use `pipes` at all.  However, the most common applications are merging
asynchronous events and broadcasting to multiple outputs.

## Development Status

`pipes-concurrency` is relatively stable.  At this point I am just adding
of 2013 then the library will be officially stabilized.

## Community Resources

Use the same resources as the core `pipes` library to learn more, contribute, or
request help:

* [Haskell wiki page](http://www.haskell.org/haskellwiki/Pipes)

* [Mailing list](mailto:haskell-pipes@googlegroups.com) ([Google Group](https://groups.google.com/forum/?fromgroups#!forum/haskell-pipes))

## How to contribute

* Build derived libraries

* Write `pipes-concurrency` tutorials

## License (BSD 3-clause)

Copyright (c) 2013 Gabriel Gonzalez
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this
  list of conditions and the following disclaimer in the documentation and/or
  other materials provided with the distribution.

* Neither the name of Gabriel Gonzalez nor the names of other contributors may
  be used to endorse or promote products derived from this software without
  specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
