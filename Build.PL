use Module::Build;
my $build = Module::Build->new(
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
        'ATry::Tiny'                => 0,
    },
);
$build->create_build_script;
