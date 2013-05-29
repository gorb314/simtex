# simtex

**sim**ple **tex**t processor

## Overview

simtex defines a couple of functions for both specifying and replacing
key/value pairs inside a body of text.
The identifying marks on the keys themselves are easily escaped,
allowing the processing to deal with natural occurences of these
marks easily.

All definitions and evaluations are also elided from the output.

This makes simtex ideal for processing source code of any kind, specifically
(but not limited to) HTML and CSS.

## Requirements

- gcc
- make
- flex
- libfl (from flex development)

## Compiling

Go to the base directory, and type "make".

## Installation

Place the src/simtex binary somewhere in your path.

## Syntax and Examples

	$KEY
	$(KEY)
	
Inserts the value of the key `KEY` into the text.
	
	$def KEY VALUE
	
Defines a key named `KEY` with a specified `VALUE`.
Note that `KEY` is a single word, while `VALUE` may contain spaces.
`KEY` and `VALUE` may contain other keys. These are evaluated on the spot.

	$def mykey value 1234

Creates a key called `mykey`, with the value `value 1234`.

	$def key1 key2
	
This defines a key called `key1`, with a value `key2`

	$def $key1 value2

This defines a key called `key2` (the evaluated value of `key1`!), with a value of `value2`

	$def $key1 $key1

This defines a key `key2` with a value `key2`

Note: evaluations are *not* recursive. They are done on the spot, which
is why the above examples work.

	$include FILENAME

Includes the processed text of `FILENAME`.
All definitions made in `FILENAME` are retained.

	$import FILENAME

Processes `FILENAME`, but discards its output/
All definitions made in `FILENAME` are retained.
	
	$inherit FILENAME

Uses the definitions and output of the current file as "specialisations"
of the definitions and output of the inherited (base) `FILENAME`.
The output of the current file may be used in the base `FILENAME` as the
special key `DERIVED`.

Note: The base file may itself specify `$inherit`, which implies that it too
has a base file, for which it in turn specialises definitions and output.
Again, its output is available to its base as `DERIVED`

In all the examples above, `FILENAME` can also be a complex value containing keys, which 
will all be evaluated to resolve the final filename to be included/imported/inherited.

	$ifdef KEY
	...
	$endif

Basic ifdef support. If `KEY` is not defined, all text between `$ifdef` and `$endif` 
is discarded and not evaluated. If `KEY` is defined, all text between `$ifdef` and `$endif` is
included and processed as normal.

## More Examples

Look in the `src/tests` subdirectory.

## Why another text (pre)processor?

Because nothing else fits the bill.

- [FMPP][1] is Java based. WTF? This is text preprocessing, not [whatever it is Java is useful for]
- [Text Preprocessor][2] could be suitable, but has an icky syntax.
- [XPP][3] is built with javascript. Great for when your operating system is "the cloud"? WTF?
- [vpp][4] *could* have been a winner. It seems to be standalone, and based on Perl. But, Perl.

The only other option would have been to (mis)use some of the Templating engines, such as [Cheetah][5], 
[Jinja 2][6] or (gods forbid) [Mako][7]. Great work guys, I'm sure these do their jobs well, just not *my* jobs.

What I want is something that is commandline based with a semi-comfortable syntax. Sort of like
bash/Makefile variable substitution, but without the headaches. Mission complete? You decide.

[1]: http://fmpp.sourceforge.net/
[2]: https://developer.mozilla.org/en-US/docs/Build/Text_Preprocessor
[3]: http://www.cross-browser.com/x/docs/xpp_reference.php
[4]: http://linux.die.net/man/1/vpp
[5]: http://www.cheetahtemplate.org/
[6]: http://jinja.pocoo.org/docs/
[7]: http://www.makotemplates.org/

## TODOs and Nice-to-haves

At the moment the entire program fits into one file that is ~~350~~about 700 lines long. The code only uses `flex`, and not `bison`, because we are not doing any complicated expression parsing, only simple evaluations and substitutions.

These items also need some clarification as to how best to implement them, before I'll proceed.

- multiline `$def`initions: Define a key to have a multiline value
- `$undef KEY`: Remove the definition of `KEY`. Does this remove all definitions, or only in the current context?
- `$override KEY`: overrides the definition of key in a base context
- `$eval KEY EXPRESSION`: assign the evaluation of the expression `EXPRESSION` as the value of `KEY`. This should ideally be done in a simple way, probably in a sandboxed lua environment?
- `$if ... $endif`: Complex `if` support. Do we need this?



