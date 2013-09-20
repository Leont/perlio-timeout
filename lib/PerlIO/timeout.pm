package PerlIO::timeout;
use strict;
use warnings;

use XSLoader;

XSLoader::load(__PACKAGE__, __PACKAGE__->VERSION);

1;

#ABSTRACT: PerlIO handles with built-in timeouts
