package MogileFS::FID;
use strict;
use warnings;
use Carp qw(croak);

sub new {
    my ($class, $fidid) = @_;
    croak("Invalid fidid") unless $fidid;
    return bless {
        fidid    => $fidid,
        dmid     => undef,
        dkey     => undef,
        length   => undef,
        classid  => undef,
        _loaded  => 0,
    }, $class;
}

# quick port of old API.  perhaps not ideal.
sub new_from_dmid_and_key {
    my ($class, $dmid, $key) = @_;
    my $row = Mgd::get_store()->file_row_from_dmid_key($dmid, $key)
        or return undef;
    $row->{fidid}   = delete $row->{fid};
    $row->{_loaded} = 1;
    return bless $row, $class;
}

# --------------------------------------------------------------------------

sub exists {
    my $self = shift;
    $self->_tryload;
    return $self->{_loaded};
}

sub classid {
    my $self = shift;
    $self->_load;
    return $self->{classid};
}

sub dmid {
    my $self = shift;
    $self->_load;
    return $self->{dmid};
}

sub length {
    my $self = shift;
    $self->_load;
    return $self->{length};
}

sub id { $_[0]{fidid} }

# force loading, or die.
sub _load {
    return 1 if $_[0]{_loaded};
    my $self = shift;
    croak("FID\#$self->fidid} doesn't exist") unless $self->_tryload;
}

# return 1 if loaded, or 0 if not exist
sub _tryload {
    return 1 if $_[0]{_loaded};
    my $self = shift;
    my $row = Mgd::get_store()->file_row_from_fidid($self->{fidid})
        or return 0;
    $self->{$_} = $row->{$_} foreach qw(dmid dkey length classid);
    $self->{_loaded} = 1;
    return 1;
}

sub update_devcount {
    my ($self, %opts) = @_;

    my $no_lock = delete $opts{no_lock};
    croak "Bogus options" if %opts;

    my $fidid = $self->{fidid};

    my $sto = Mgd::get_store();
    if ($no_lock) {
        return $sto->update_devcount($fidid);
    } else {
        return $sto->update_devcount_atomic($fidid);
    }
}

sub enqueue_for_replication {
    my ($self, %opts) = @_;
    my $in       = delete $opts{in};
    my $from_dev = delete $opts{from_device};  # devid or Device object
    croak("Unknown options to enqueue_for_replication") if %opts;
    my $from_devid = (ref $from_dev ? $from_dev->id : $from_dev) || undef;
    Mgd::get_store()->enqueue_for_replication($self->id, $from_devid, $in);

    # wake up a replicator, to reduce replication latency (will happen
    # on its own otherwise, polling)
    MogileFS::ProcManager->wake_a("replicate");
}

sub mark_unreachable {
    my $self = shift;
    # update database table
    Mgd::get_store()->mark_fidid_unreachable($self->id);
}

sub delete {
    my $fid = shift;
    my $sto = Mgd::get_store();
    $sto->delete_fidid($fid->id);
}

# returns 1 on success, 0 on duplicate key error, dies on exception
sub rename {
    my ($fid, $to_key) = @_;
    my $sto = Mgd::get_store();
    return $sto->rename_file($fid->id, $to_key);
}

# returns array of devids that this fid is on
sub devids {
    my $self = shift;
    return Mgd::get_store()->fid_devids($self->id);
}

# return FID's class
sub class {
    my $self = shift;
    return MogileFS::Class->of_fid($self);
}

1;

__END__

=head1 NAME

MogileFS::FID - represents a unique, immutable version of a file

=head1 ABOUT

This class represents a "fid", or "file id", which is a unique
revision of a file.  If you upload a file with the same key
("filename") a dozen times, each one has a unique "fid".  Fids are
immutable, and are what are replicated around the MogileFS farm.