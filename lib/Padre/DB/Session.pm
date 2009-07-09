#
# This class is indented to be automatically loaded by Padre::DB,
# overloading the code already auto-generated by Padre::DB.
#

package Padre::DB::Session;

use strict;
use warnings;

our $VERSION = '0.39';

my $PADRE_SESSION = 'padre-last';

sub last_padre_session {

	# find last padre session
	my ($padre) = Padre::DB::Session->select(
		'where name = ?',
		$PADRE_SESSION
	);

	# no such session, create one
	if ( not defined $padre ) {
		$padre = Padre::DB::Session->new(
			name        => $PADRE_SESSION,
			description => 'Last session within Padre',
			last_update => time,
		);
		$padre->insert;
	}
	return $padre;
}

sub files {
	my ($self) = @_;
	my @files = Padre::DB::SessionFile->select(
		'where session = ?',
		$self->id
	);
	return @files;
}

1;

__END__


=pod

=head1 NAME

Padre::DB::Session - db table keeping known padre sessions



=head1 SYNOPSIS

        my @sessions = Padre::DB::Session->select;



=head1 DESCRIPTION

This class allows storing in Padre's database the session that Padre knows.
This is useful in order to quickly restore a given set of files.

This is the primary table, you also need to check C<Padre::DB::SessionFiles>.



=head1 PUBLIC METHODS

=head2 Accessors

The following accessors are automatically created by C<ORLite>:

=over 4

=item id()

=item name()

=item description()

=item last_update()

=back


=head2 Autogenerated class methods

The following subs are automatically created by C<ORLite>. Refer to C<ORLite>
for more information on them:

=over 4

=item select()

=item count()

=item new()

=item create()

=item insert()

=item delete()

=item truncate()

=back


=head2 Class methods

=over 4

=item my $session = last_padre_session()

Return a C<Padre::DB::Session> object pointing to last Padre session. If
none exists, a new one will be created and returned.

=back


=head2 Instance methods

=over 4

=item my @files = $session->files()

Return a list of files (C<Padre::DB::SessionFile> objects) referenced by
current C<$session>.


=back



=head1 COPYRIGHT & LICENSE

Copyright 2008-2009 The Padre development team as listed in Padre.pm.

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=cut

# Copyright 2008-2009 The Padre development team as listed in Padre.pm.
# LICENSE
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl 5 itself.
