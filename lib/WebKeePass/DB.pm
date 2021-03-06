package WebKeePass::DB;
#ABSTRACT: module to access the KeePass database

=head1 DESCRIPTION

This module is here to wrap all the access knowledge to the KeePass database.

=cut

use Moo;
use Carp 'croak'; 
use File::KeePass;
use DateTime;
use Data::Dumper;
use Digest::SHA1 'sha1_hex';
use Encode 'encode';

=attr db_file 

The path to the KeePass DB file to handle

=cut

has db_file => (
    is => 'ro',
    required => 1,
);

=attr keepass

The File::KeePass object built with the db_file

=cut

has keepass => (
    is => 'rw',
    lazy => 1,
    builder => '_build_keepass',
);

sub _build_keepass { File::KeePass->new }

=method load_db

Method to open the DB file, with the master password.

=cut

sub load_db {
    my ($self, $master_password) = @_;
    $self->keepass->load_db($self->db_file, $master_password);    
    $self->keepass->unlock;
}

=attr entries

Retreive all the entries in the DB that have a title, a username and a password

=cut

has entries => (
    is => 'rw',
    lazy => 1,
    builder => '_build_entries',
);

sub _parse_entries {
    my ( $self, $data ) = @_;
    my $entries = $data || [];
    my @entries;

    foreach my $entry ( @{$entries} ) {

        my $e = {
            id => sha1_hex(
                    encode( 'UTF-8', $entry->{title} || '')
                  . encode( 'UTF-8', $entry->{username} || '')
                  . encode( 'UTF-8', $entry->{password} || '')
            )
        };
        my @fields = qw(title username password comment url);
        map { $e->{$_} = $entry->{$_}} @fields;

        push @entries, $e
          if defined $e->{title} && 
             defined $e->{username} && 
             defined $e->{password};
    }

    #use Data::Dumper;
    #warn Dumper(\@entries);
    return \@entries;
}

sub _build_entries {
    my ($self) = @_;
    my $groups = $self->_parse_group( $self->keepass->groups );
#    print Dumper($groups);
    return $groups;
}

sub _parse_group {
    my ($self, $data) = @_;
    my $groups = [];

    foreach my $item ( @{ $data } ) {
        my $entries = $self->_parse_entries( $item->{entries} );

        push @{$groups},
          {
            title   => $item->{title},
            #icon    => $item->{icon},
            entries => $entries,
            group   => $self->_parse_group( $item->{groups} ),
          };
    }

    return $groups;
}

sub _count_entries {
    my ($self, $entries) = @_;
    my $count = 0;
    $entries ||= $self->entries;

    for my $e (@{ $entries }) {
        $count += scalar @{ $e->{entries} };
        $count += $self->_count_entries( $e->{group} );
    }

    return $count;
}

sub get_group_by_path {
    my ($self, $tree, @path) = @_;
    my $buffer_tree = $tree;
    my $found;

    while (my $name = shift @path) {
        undef $found;

        foreach my $group ( @{$buffer_tree} ) {
            if ( $group->{title} eq $name ) {
                $found = $group;
                $buffer_tree = $found->{group};
                last;
            }
        }
        return undef if ! defined $found;
    }

    # here, buffer_tree is at the the level we want, and all part of paths have been
    # found successively
    return $found;
}

sub entry_by_id {
    my ( $class, $entries, $id ) = @_;

    foreach my $group ( @{$entries} ) {
        foreach my $item ( @{ $group->{entries} } ) {
            return $item if $item->{id} eq $id;
        }
        my $found = $class->entry_by_id( $group->{group}, $id );
        return $found if defined $found;
    }

    return undef;
}

=attr stats

HashRef with stats info about the DB file

=cut

has stats => (
    is      => 'rw',
    lazy => 1,
    builder => '_build_stats', 
);

sub _build_stats {
    my ($self) = @_;
    my $raw =$self->keepass->header;

    my @stat = stat( $self->db_file );
    my $dt = DateTime->from_epoch( epoch => $stat[9] );
    my $last_modified = $dt->ymd('-').' '.$dt->hms(':');
    
    return {
        version        => $raw->{version},
        generator      => $raw->{generator},
        name           => $raw->{database_name},
        key_updated_at => $raw->{master_key_changed},
        last_modified  => $last_modified,
        encoding       => $raw->{enc_type},
        cipher         => $raw->{cipher},
        entries        => $self->_count_entries,
    };
}

1;
