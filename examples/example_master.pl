#!/usr/bin/env perl

use Modern::Perl '2014';

use AnyEvent;
use Try::Tiny;
use Scalar::Util qw(blessed);
use Net::FailOver;

my ($d) = try {
    my $d = Net::FailOver->new(
        my_address      => '10.103.112.52',
        my_port         => '11162',
        my_priority     => 20,
        partner_address => '10.103.112.52',
        partner_port    => '11163',
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

my $timer = AnyEvent->timer(
    after       => 1,
    interval    => 1,
    cb          => sub { $d->is_master ? say "I am master" : say "I am slave" }
);

my $cv_recv = AnyEvent->condvar;
$cv_recv->recv;
