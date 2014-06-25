package Net::FailOver;
# ABSTRACT: AnyEvent based module to provide master/slave failover
use Modern::Perl '2012';
use Moose;
use Moose::Util::TypeConstraints;
use MooseX::StrictConstructor;
use Regexp::Common qw/ net /;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
# VERSION

with 'MooseX::LogDispatch';

subtype 'IPAddress',
    as 'Str',
    where { m/$RE{net}{IPv4}/ },
    message { "$_ is not a valid IP address" }
;

subtype 'PortNumber',
    as 'Int',
    where { $_> 0 && $_ < 65536 },
    message { "$_ is not a valid port number" }
;

## Public Attributes ##

has [ 'my_address', 'partner_address' ] => ( 
    is          => 'ro',
    isa         => 'IPAddress',
    required    => 1,
);

has [ 'my_port', 'partner_port' ] => ( 
    is          => 'ro',
    isa         => 'PortNumber',
    required    => 1,
    default     => 1162,
);

has 'my_priority' => (
    is          => 'rw',
    isa         => 'Int',
    required    => 1,
    default     => 10
);

has 'hold_time' => ( 
    is          => 'rw',
    isa         => 'Int',
    default     => 10
);

has 'interval' => (
    is      => 'rw',
    isa     => 'Int',
    default => 1,
);

has 'is_master' => (
    is      => 'ro',
    traits  => ['Bool'],
    isa     => 'Bool',
    default => 1,
    handles => {
        _become_master  => 'set',
        _become_slave   => 'unset',
        is_slave        => 'not',
    }
);

has 'debug' => (
    is      => 'rw',
    isa     => "Bool",
    default => 0,
);

has 'log_dispatch_conf' => (
    is          => 'ro',
    isa         => 'HashRef',
    lazy        => 1,
    required    => 1,
    default     => sub {
        my ($self) = @_;
        return $self->debug ? {
            class       => 'Log::Dispatch::Screen',
            min_level   => 'debug',
            stderr      => 1,
            format      => '[%p] %m at %F line %L%n',
        } : {
            class       => 'Log::Dispatch::Screen',
            min_level   => 'warning',
            stderr      => 1,
            format      => '[%p] %m at %F line %L%n',
        };
    },
);

has 'use_logger_singleton' => (
    is      => 'rw',
    isa     => "Bool",
    default => 1,
);

## Internal Attributes ##

has '_send_handle' => (
    is          => 'rw',
    isa         => 'AnyEvent::Handle',
    documentation =>
        "TCP connection used to send keepalives to partner",
);

has '_recv_handle' => (
    is          => 'rw',
    isa         => 'AnyEvent::Handle',
    documentation =>
        "TCP connection used to receive keepalives from partner",
);

has '_keepalive_timer' => (
    is          => 'rw',
    isa         => 'Maybe[EV::Timer]',
    documentation =>
        "Timer which sends keepalives periodically to partner, keeps running every \$self->interval seconds until stopped.",
);

has '_reconnect_timer' => (
    is          => 'rw',
    isa         => 'Maybe[EV::Timer]',
    documentation =>
        "Timer which waits \$self->_reconnect_seconds then triggers an attempt to establish a TCP session with partner. Runs once.",
);

has '_partner_loss_timer' => (
    is          => 'rw',
    isa         => 'Maybe[EV::Timer]',
    documentation =>
        "Timer which waits \$self->_hold_time then marks the partner dead and triggers mastership change. Runs once. Reset by keepalive_timer event",
);

has '_partner_priority' => (
    is          => 'rw',
    isa         => 'Int',
    default     => 0,
    required    => 1,
    documentation =>
        "Partners priority, obtained from partners keepalive message",
);

has '_reconnect_seconds' => (
    is          => 'rw',
    isa         => 'Int',
    default     => 5,
    required    => 1,
    documentation =>
        "How long to wait until attempting to reconnect TCP session, drives _reconnect_timer",
);

sub BUILD
{
    my ($self) = @_;

    my $my_socket = $self->my_address . ":" . $self->my_port;
    $my_socket =~ s/ +//g;

    my $partner_socket = $self->partner_address . ":" . $self->partner_port;
    $partner_socket =~ s/ +//g;

    $self->logger->debug("Creating failover between $my_socket and $partner_socket");

    if ($my_socket eq $partner_socket){
        $self->logger->critical("Initialisation failed");
        Net::FailOver::Exception::Init->throw({ message => "Our address and port cannot match partner address and port" });
    }
}

# Public Methods

sub start
{
    my ($self) = @_;

    $self->logger->debug("Starting failover process");
    $self->_listen;
    $self->_connect;

    return;
}

sub stop
{
    my ($self) = @_;

    $self->logger->debug("Stopping failover process");
    $self->_stop_listening;
    $self->_disconnect;

    return;
}

sub partner_priority
{
    my ($self) = @_;

    return $self->_partner_priority;
}

# Private Methods

sub _listen
{
    my ($self) = @_;

    $self->logger->debug("Attempting to open port");
    #warn "Need to check what error and eof mean, should I throw?";

    tcp_server $self->my_address, $self->my_port => sub {
        my ($fh, $host, $port) = @_;
    
        $self->_recv_handle(AnyEvent::Handle->new(
            fh => $fh,
            on_error => sub {
                $self->logger->critical("Error in listener");
            },
            on_eof => sub {
                $self->logger->debug("Partner disconnected");
                $self->_partner_down();
            },
            on_read => sub {
                my ($h) = @_;
                $self->logger->debug("Got keepalive from partner");
                $h->unshift_read( line => sub {
                    my ($h, $data) = @_;
                    my ($attr, $val) = split "=", $data;
                    if ($attr and $attr eq 'PRIORITY'){
                        $self->logger->debug("Partner sent priority $val");
                        $self->_partner_priority($val);
                        $self->_determine_mastership();
                    }
                    $self->logger->debug("Resetting loss timer");
                    $self->_start_partner_loss_timer();
                });
            },
        ));
    };

    $self->logger->debug("Port opened succcessfully, listening");
    return;
}

sub _stop_listening
{
    my ($self) = @_;

    $self->logger->debug("Closing port and destroying object");
    $self->_recv_handle->destroy;
    $self->_recv_handle(undef);
    return;
}

sub _disconnect
{
    my ($self) = @_;

    $self->logger->debug("Disconnecting from remote server and destroying object");
    $self->_send_handle->destroy;
    $self->_send_handle(undef);
    return;
}

sub _determine_mastership
{
    my ($self) = @_;

    $self->logger->debug("Determining master");
    $self->logger->debug("My priority is " . $self->my_priority);
    $self->logger->debug("Their priority is " . $self->partner_priority);

    if ($self->my_priority > $self->_partner_priority){
        $self->logger->debug("I am master");
        $self->_become_master;
        return;
    }

    if ($self->_partner_priority > $self->my_priority){
        $self->logger->debug("I am slave");
        $self->_become_slave;
        return;
    }

    if ($self->_partner_priority == $self->my_priority){
        $self->logger->debug("Priorities match, tie break on IP address: ", $self->my_address . " vs " . $self->partner_address);
        my $my_socket = $self->my_address . ":" . $self->my_port;
        my $their_socket = $self->partner_address . ":" . $self->partner_port;
        if ($my_socket gt $their_socket){
            $self->logger->debug("I am master");
            $self->_become_master();
        }else{
            $self->logger->debug("I am slave");
            $self->_become_slave();
        }
    }

    return;
}

sub _start_partner_loss_timer
{
    my ($self) = @_;
    
    $self->logger->debug("Starting partner loss timer");
    $self->_partner_loss_timer(AnyEvent->timer(
        after   => $self->hold_time,
        cb      => sub { 
            $self->logger->debug("Partner loss timeout reached");
            $self->_partner_down
        },
    ));

    return;
}

sub _partner_down
{
    my ($self) = @_;
    
    $self->logger->debug("Lost partner, becoming master");
    $self->_become_master();
    return;
}

sub _connect
{
    my ($self) = @_;

    $self->logger->debug("Attempting to connect to partner");
    tcp_connect $self->partner_address, $self->partner_port => sub {
        my ($fh) = @_;
        $self->logger->debug("Connection to partner estabalished");

        if ($fh){
            $self->_send_handle( AnyEvent::Handle->new(
                fh => $fh,
                on_error => sub {
                    my ($hdl, $fatal, $msg) = @_;
                    $self->_send_handle->destroy;
                    $self->logger->debug("Error in sender: $msg");
                    $self->_start_reconnect_timer();
                },
                on_eof => sub {
                    $self->_send_handle->destroy;
                    $self->logger->debug("Sender connection closed");
                    $self->_start_reconnect_timer();
                },
            ));

            $self->_start_keepalive_timer();
        }else{
            $self->logger->debug("Connection to partner failed");
            $self->_start_reconnect_timer();
        }
    };
    return;
}

sub _start_keepalive_timer
{
    my ($self) = @_;

    $self->logger->debug("Starting keepalive timer");
    $self->_keepalive_timer(AnyEvent->timer(
        after       => $self->interval,
        interval    => $self->interval,
        cb          => sub { $self->_send_keepalive },
    ));
}

sub _stop_keepalive_timer
{
    my ($self) = @_;

    $self->logger->debug("Stopping keepalive timer");
    $self->_keepalive_timer(undef);
}

sub _send_keepalive
{
    my ($self) = @_;

    $self->logger->debug("Sending keepalive with priority " . $self->my_priority);
    $self->_send_handle->push_write("PRIORITY=" . $self->my_priority . "\n");
}

sub _start_reconnect_timer
{
    my ($self) = @_;

    $self->logger->debug("Starting reconnection timer");
    $self->_stop_keepalive_timer();

    $self->_reconnect_timer(AnyEvent->timer(
        after   => $self->_reconnect_seconds,
        cb      => sub{
            $self->logger->debug("Reconnect timeout expired");
            $self->_connect();
        }
    ));
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;

=head1 NAME

Net::FailOver - Allow two daemons to maintain a master/slave relationship

=head1 SYNOPSIS

  use Net::FailOver;

  # Create and configure object
  my $fo = Net::FailOver->new(
    my_address      => '10.0.0.1',
    my_port         => '1162',
    my_priority     => '10',
    partner_address => '10.0.1.1',
    partner_port    => '1162',
  );

  # Start all internal timers and determine mastership
  $fo->start;

  # .. later somewhere
  if ($fo->is_master){
    master_task();
  }

=head1 DESCRIPTION

Net::FailOver is a small module based on L<AnyEvent> that allows two daemons to maintain a master/slave relationship.

Being based on AnyEvent, Net::FailOver should integrate nicely with code using any of the event loops that integrate nicely with AnyEvent.

Internally, TCP sessions are created between the master and slave processes which are used to exchange keepalive messages. The loss of the TCP session or a failure to receive keepalives in the specified time period will cause the daemon to assume the master role. In practice this simply means that a call to $fo->is_master returns true (or a call to $fo->is_slave returns false), you can make use of this within your code to perform operations differently depending on your particular needs.

=head1 METHODS

=for Pod::Coverage BUILD

=head2 new() - create a new Net::FailOver object

  my $fo = Net::FailOver->new(
    my_address      => $local_ip_address,
    partner_address => $remote_ip_address,
    [ my_port       => $local_tcp_port,]        #default 1162
    [ partner_port  => $remote_tcp_port, ]      #default 1162
    [ my_priority   => $priority, ]             #default 10
    [ interval      => $interval, ]             #seconds, default 1
    [ hold_time     => $hold_time, ]            #seconds, default 10
    [ is_master     => $master_state, ]         #default 1
    [ debug         => $enable_debugging, ]     #default 0
  );

This is the constructor for Net::FailOver objects. It will return a reference to a new object on success and will throw a Net::FailOver::Exception on failure. The only two arguments are required during initialisation: a local IP address to bind to and the IP address of the partner; neither of these can be changed after the object has been initialised. The remaining arguments are optional, can be changed at any time using their accessor methods and are described in more detail in the following sections.

=head2 start() - begins the failover process

  $fo->start();

Starts the failover process by listening for incoming connections from partner, establishing a connection to the partner and starting all timers.

=head2 stop() - ends the failover process

  $fo->stop();

Stops the failover process.

=head2 my_address() - returns local address

  my $local = $fo->my_address();

=head2 partner_address() - returns remote address

  my $remote = $fo->partner_address();

=head2 my_port()

  $fo->my_port('1234');

  my $port = $fo->my_port();

Retrieves or sets the local TCP port number. Setting this value has no effect to a failover session that is currently in progress, in order to have an effect it should be used either at construction or before calling $fo->start(). 

=head2 partner_port()

  $fo->partner_port('1234');

  my $port = $fo->partner_port();

Retrieves or sets the remote TCP port number. Setting this value has no effect to a failover session that is currently in progress, in order to have an effect it should be used either at construction or before calling $fo->start(). 

=head2 my_priority()

  $fo->my_priority('20');

  my $prio = $fo->my_priority();

Retrieves or sets the priority of the failover instance, with the highest being prefered. Can be set at any time and will take immediate effect. Both members of the failover session having equal priorities will result in the highest IP address and port number combination will be used as a tie breaker.

=head2 partner_priority()

  my $prio = $fo->partner_priority();

Retrieves the priority of the partner failover instance. Only makes sense to use this after start() has been called as the partner priority is signalled by the remote end.

=head2 interval()

  $fo->interval('5');

  my $interval = $fo->interval();

Retrieves or sets the interval in seconds at which the local instance will send keepalive messages. This must be set before the failover session is started to work correctly.

=head2 hold_time()

  $fo->hold_time('15');

  my $ht = $fo->hold_time();

Retrieves or sets the hold time in seconds. If this period expires without receipt of a keepalive message from the remote host the local instance will declare the host lost and assume mastership. Ideally this should be x times the interval where x is the number of keepalives you are happy to lose.

=head2 is_master()

    if ($fo->is_master){
        print "I am the master\n";
    }

Returns a true value if the local instance of Net::FailOver considers itself the master.

=head2 is_slave()

    if ($fo->is_slave){
        print "I am not the master\n";
    }

Returns a true value if the local instance of Net::FailOver considers itself the slave. This is the inverse of is_master().

=head2 debug()

    $fo->debug(1);

    my $is_debugging = $fo->debug();

Retrieves or sets the debugging state. If set to true the module will output a great deal of debugging information.

=head1 EXAMPLES

See the contents of the examples directory in the distribution for examples of how to use this module as a master and a slave. Also, the examples show the module used within an program based on AnyEvent and another based on POE. More examples to follow of using other event frameworks.

=head1 SEE ALSO

I'm not currently aware of any modules providing the same functionality. Please let me know if any exist.

=head1 AUTHORS

Sean Maguire
