#!/usr/bin/env perl

use Modern::Perl '2014';

use Try::Tiny;
use Scalar::Util qw(blessed);
use Net::FailOver;
use POE;

my ($d) = try {
    my $d = Net::FailOver->new(
        my_address      => '10.103.112.52',
        my_port         => '11163',
        partner_address => '10.103.112.52',
        partner_port    => '11162',
        is_master       => 0,
        debug           => 1,
    );

    $d->start();
    return $d;
} catch {
    die $_ unless blessed $_;
    
    if ($_->isa('Net::FailOver::Exception')){
        say $_->blessed() . ": " . $_->message;
    }else{
        say "Unknown exception " . blessed $_ . ": $_";
    }
};

POE::Session->create(
    inline_states => {
        _start => sub {
            $_[KERNEL]->delay(tick => 1);
        },

        tick => sub {
            $d->is_master ? say "I am master" : say "I am slave";
            $_[KERNEL]->delay(tick => 1);
        },
    },
);

POE::Kernel->run();
