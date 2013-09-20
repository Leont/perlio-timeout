#! perl

use strict;
use warnings;

use Test::More;

use open IO => ":timeout(1)";
alarm 2;
my $pid = open my $fh, "-|", "echo Hi; sleep 5; echo There" or die "$!";
my @lines = do { local $/; <$fh> };
chomp @lines;
kill 15, $pid;
close $fh;

is_deeply(\@lines, [qw/Hi/], 'Only got \'Hi\', not \'There\'');

#say ":$_" for PerlIO::get_layers($fh)

done_testing;
