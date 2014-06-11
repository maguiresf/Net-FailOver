package Net::FailOver::Exception;

use Moose;

with 'Throwable';

has 'message' => (is => 'ro', isa => 'Str');

no Moose;

=head1 NAME

Net::FailOver::Exception - Exception class to support Net::FailOver

=head1 METHODS

=head2 message()

The message which will be included in the thrown exception

=cut

__PACKAGE__->meta->make_immutable;

package Net::FailOver::Exception::Init;

use Moose;

extends 'Net::FailOver::Exception';

no Moose;
__PACKAGE__->meta->make_immutable;

package Net::FailOver::Exception::Listen;

use Moose;

extends 'Net::FailOver::Exception';

no Moose;
__PACKAGE__->meta->make_immutable;
1;
