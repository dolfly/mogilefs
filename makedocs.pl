#!/usr/bin/perl

use strict;

my $base = "/home/lj/htdocs/dev/mogdocs/";
my $pshb = Goats->new;
$pshb->batch_convert([qw(mogstored mogilefsd lib)], $base);

package Goats;

use strict;
use base 'Pod::Simple::HTMLBatch';

sub modnames2paths {
    my ($self, $dirs) = @_;

    my @files;
    my @dirs;

    foreach my $path (@{$dirs || []}) {
        if (-f $path) {
            push @files, $path;
        } else {
            push @dirs, $path;
        }
    }

    my $m2p = $self->SUPER::modnames2paths(\@dirs);

    foreach my $file (@files) {
        my ($tail) = $file =~ m!([^/]+)\z!;
        $m2p->{$tail} = $file;
    }

    return $m2p;
}
