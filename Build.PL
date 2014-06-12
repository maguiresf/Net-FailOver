use Module::Build;
my $build = Module::Build->new(
    build_requires  => {
        'Module::Build'     => 0,
    },
    configure_requires  => {
        'Module::Build'     => 0,
    },
    dist_abstract           => 'AnyEvent based module to provide master/slave failover',
    dist_author             => 'Sean Maguire <maguiresf@gmail.com>',
    dist_name               => 'Net-FailOver',
    dist_version            => '0.1',
    module_name => 'Net::FailOver',
    license  => 'perl',
    requires => {
        'perl'                      => '5.14.0',
        'AnyEvent'                  => 0,
        'AnyEvent::Handle'          => 0,
        'AnyEvent::Socket'          => 0,
        'Modern::Perl'              => 0,
        'Moose'                     => 0,
        'MooseX::StrictConstructor' => 0,
        'Regexp::Common'            => 0,
        'Scalar::Util'              => 0,
        'Try::Tiny'                 => 0,
        'MooseX::LogDispatch'       => 0,
    },
    test_requires           => {
        "Test::More"    => 0,
    },
);
$build->create_build_script;
