package MogileFS::Store;
use strict;
use warnings;
use Carp qw(croak);
use MogileFS::Util qw(throw);
use DBI;  # no reason a Store has to be DBI-based, but for now they all are.

# this is incremented whenever the schema changes.  server will refuse
# to start-up with an old schema version
use constant SCHEMA_VERSION => 7;

sub new {
    my ($class) = @_;
    return $class->new_from_dsn_user_pass(map { MogileFS->config($_) } qw(db_dsn db_user db_pass));
}

sub new_from_dsn_user_pass {
    my ($class, $dsn, $user, $pass) = @_;
    my $subclass;
    if ($dsn =~ /^DBI:mysql:/i) {
        $subclass = "MogileFS::Store::MySQL";
    } elsif ($dsn =~ /^DBI:SQLite:/i) {
        $subclass = "MogileFS::Store::SQLite";
    } elsif ($dsn =~ /^DBI:Oracle:/i) {
        $subclass = "MogileFS::Store::Oracle";
    } elsif ($dsn =~ /^DBI:Pg:/i) {
        $subclass = "MogileFS::Store::Postgres";
    } else {
        die "Unknown database type: $dsn";
    }
    my $self = bless {
        dsn    => $dsn,
        user   => $user,
        pass   => $pass,
        raise_errors => $class->want_raise_errors,
    }, $subclass;
    unless (eval "use $subclass; 1") {
        die "Error loading $subclass: $@\n";
    }
    $self->init;
    return $self;
}

sub want_raise_errors {
     # will default to true later
    0;
}

sub new_from_mogdbsetup {
    my ($class, %args) = @_;
    # where args is:  dbhost dbname dbrootuser dbrootpass dbuser dbpass
    my $dsn = $class->dsn_of_dbhost($args{dbname}, $args{dbhost});

    my $try_make_sto = sub {
        my $dbh = DBI->connect($dsn, $args{dbuser}, $args{dbpass}, {
            PrintError => 0,
        }) or return undef;
        my $sto = $class->new_from_dsn_user_pass($dsn, $args{dbuser}, $args{dbpass});
        $sto->raise_errors;
        return $sto;
    };

    # upgrading, apparently, as this database already exists.
    my $sto = $try_make_sto->();
    return $sto if $sto;

    # otherwise, we need to make the requested database, setup permissions, etc
    $class->status("couldn't connect to database as mogilefs user.  trying root...");
    my $rdbh = DBI->connect($class->dsn_of_root, $args{dbrootuser}, $args{dbrootpass}, {
        PrintError => 0,
    }) or
        die "Failed to connect to $dsn as specified root user: " . DBI->errstr . "\n";
    $class->status("connected to database as root user.");

    $class->confirm("Create database name '$args{dbname}'?");
    $class->create_db_if_not_exists($rdbh, $args{dbname});
    $class->confirm("Grant all privileges to user '$args{dbuser}', connecting from anywhere, to the mogilefs database '$args{dbname}'?");
    $class->grant_privileges($rdbh, $args{dbname}, $args{dbuser}, $args{dbpass});

    # should be ready now:
    $sto = $try_make_sto->();
    return $sto if $sto;

    die "Failed to connect to database as regular user, even after creating it and setting up permissions as the root user.";
}

sub create_db_if_not_exists {
    my ($pkg, $rdbh, $dbname) = @_;
    $rdbh->do("CREATE DATABASE $dbname")
        or die "Failed to create database '$dbname': " . $rdbh->errstr . "\n";
}

sub grant_privileges {
    my ($pkg, $rdbh, $dbname, $user, $pass) = @_;
    $rdbh->do("GRANT ALL PRIVILEGES ON $dbname.* TO $user\@'\%' IDENTIFIED BY ?",
             undef, $pass)
        or die "Failed to grant privileges: " . $rdbh->errstr . "\n";
    $rdbh->do("GRANT ALL PRIVILEGES ON $dbname.* TO $user\@'localhost' IDENTIFIED BY ?",
             undef, $pass)
        or die "Failed to grant privileges: " . $rdbh->errstr . "\n";
}

sub can_replace      { 0 }
sub can_insertignore { 0 }

sub ignore_replace {
    my $self = shift;
    return "INSERT IGNORE " if $self->can_insertignore;
    return "REPLACE " if $self->can_replace;
    die "Can't INSERT IGNORE or REPLACE?";
}

my $on_status = sub {};
my $on_confirm = sub { 1 };
sub on_status  { my ($pkg, $code) = @_; $on_status  = $code; };
sub on_confirm { my ($pkg, $code) = @_; $on_confirm = $code; };
sub status     { my ($pkg, $msg)  = @_; $on_status->($msg);  };
sub confirm    { my ($pkg, $msg)  = @_; $on_confirm->($msg) or die "Aborted.\n"; };

sub latest_schema_version { SCHEMA_VERSION }

sub raise_errors {
    my $self = shift;
    $self->{raise_errors} = 1;
    $self->dbh->{RaiseError} = 1;
}

sub dsn  { $_[0]{dsn}  }
sub user { $_[0]{user} }
sub pass { $_[0]{pass} }

sub init { 1 }
sub post_dbi_connect { 1 }

sub recheck_dbh {
    my $self = shift;
    $self->{needs_ping} = 1;
}

sub dbh {
    my $self = shift;
    if ($self->{dbh}) {
        if ($self->{needs_ping}) {
            $self->{needs_ping} = 0;
            $self->{dbh} = undef unless $self->{dbh}->ping;
        }
        return $self->{dbh} if $self->{dbh};
    }

    $self->{dbh} = DBI->connect($self->{dsn}, $self->{user}, $self->{pass}, {
        PrintError => 0,
        AutoCommit => 1,
        # FUTURE: will default to on (have to validate all callers first):
        RaiseError => ($self->{raise_errors} || 0),
    }) or
        die "Failed to connect to database: " . DBI->errstr;
    $self->post_dbi_connect;
    return $self->{dbh};
}

sub ping {
    my $self = shift;
    return $self->dbh->ping;
}

sub condthrow {
    my ($self, $optmsg) = @_;
    my $dbh = $self->dbh;
    return unless $dbh->err;
    my ($pkg, $fn, $line) = caller;
    my $msg = "Database error from $pkg/$fn/$line: " . $dbh->errstr;
    $msg .= ": $optmsg" if $optmsg;
    croak($msg);
}

sub dowell {
    my ($self, $sql, @do_params) = @_;
    my $rv = eval { $self->dbh->do($sql, @do_params) };
    return $rv unless $@ || $self->dbh->err;
    warn "Error with SQL: $sql\n";
    Carp::confess($@ || $self->dbh->errstr);
}

sub _valid_params {
    croak("Odd number of parameters!") if scalar(@_) % 2;
    my ($self, $vlist, %uarg) = @_;
    my %ret;
    $ret{$_} = delete $uarg{$_} foreach @$vlist;
    croak("Bogus options") if %uarg;
    return %ret;
}

sub was_duplicate_error {
    my $self = shift;
    my $dbh = $self->dbh;
    die "UNIMPLEMENTED";
}

# run a subref (presumably a database update) in an eval, because you expect it to
# maybe fail on duplicate key error, and throw a dup exception for you, else return
# its return value
sub conddup {
    my ($self, $code) = @_;
    my $rv = eval { $code->(); };
    throw("dup") if $self->was_duplicate_error;
    return $rv;
}

# --------------------------------------------------------------------------

sub setup_database {
    my $sto = shift;

    # schema history:
    #   7: adds file_to_delete_later table
    my $curver = $sto->schema_version;

    my $latestver = SCHEMA_VERSION;
    if ($curver == $latestver) {
        status("Schema already up-to-date at version $curver.");
        return 1;
    }

    if ($curver > $latestver) {
        die "Your current schema version is $curver, but this version of mogdbsetup only knows up to $latestver.  Aborting to be safe.\n";
    }

    if ($curver) {
        confirm("Install/upgrade your schema from version $curver to version $latestver?");
    }

    foreach my $t (qw(
                      domain class file tempfile file_to_delete
                      unreachable_fids file_on file_on_corrupt host
                      device server_settings file_to_replicate
                      file_to_delete_later
                      )) {
        $sto->create_table($t);
    }

    $sto->upgrade_add_host_getport;
    $sto->upgrade_add_host_altip;
    $sto->upgrade_add_device_asof;
    $sto->upgrade_add_device_weight;
    $sto->upgrade_add_device_readonly;

    return 1;
}

sub schema_version {
    my $self = shift;
    my $dbh = $self->dbh;
    return eval {
        $dbh->selectrow_array("SELECT value FROM server_settings WHERE field='schema_version'") || 0;
    } || 0;
}

sub filter_create_sql { my ($self, $sql) = @_; return $sql; }

sub create_table {
    my ($self, $table) = @_;
    my $dbh = $self->dbh;
    return 1 if $self->table_exists($table);
    my $meth = "TABLE_$table";
    my $sql = $self->$meth;
    $sql = $self->filter_create_sql($sql);
    $self->status("Running SQL: $sql;");
    $dbh->do($sql) or
        die "Failed to create table $table: " . $dbh->errstr;
    my $imeth = "INDEXES_$table";
    my @indexes = eval { $self->$imeth };
    foreach $sql (@indexes) {
        $self->status("Running SQL: $sql;");
        $dbh->do($sql) or
            die "Failed to create indexes on $table: " . $dbh->errstr;
    }
}


sub TABLE_domain {
    # classes are tied to domains.  domains can have classes of items
    # with different mindevcounts.
    #
    # a minimum devcount is the number of copies the system tries to
    # maintain for files in that class
    #
    # unspecified classname means classid=0 (implicit class), and that
    # implies mindevcount=2
    "CREATE TABLE domain (
   dmid         SMALLINT UNSIGNED NOT NULL PRIMARY KEY,
   namespace    VARCHAR(255),
   UNIQUE (namespace))"
}

sub TABLE_class {
    "CREATE TABLE class (
      dmid          SMALLINT UNSIGNED NOT NULL,
      classid       TINYINT UNSIGNED NOT NULL,
      PRIMARY KEY (dmid,classid),
      classname     VARCHAR(50),
      UNIQUE      (dmid,classname),
      mindevcount   TINYINT UNSIGNED NOT NULL
)"
}

# the length field is only here for easy verifications of content
# integrity when copying around.  no sums or content types or other
# metadata here.  application can handle that.
#
# classid is what class of file this belongs to.  for instance, on fotobilder
# there will be a class for original pictures (the ones the user uploaded)
# and a class for derived images (scaled down versions, thumbnails, greyscale, etc)
# each domain can setup classes and assign the minimum redundancy level for
# each class.  fotobilder will use a 2 or 3 minimum copy redundancy for original
# photos and and a 1 minimum for derived images (which means the sole device
# for a derived image can die, bringing devcount to 0 for that file, but
# the application can recreate it from its original)
sub TABLE_file {
    "CREATE TABLE file (
   fid          INT UNSIGNED NOT NULL,
   PRIMARY KEY  (fid),

   dmid          SMALLINT UNSIGNED NOT NULL,
   dkey           VARCHAR(255),     # domain-defined
   UNIQUE dkey  (dmid, dkey),

   length        INT UNSIGNED,        # 4GB limit

   classid       TINYINT UNSIGNED NOT NULL,
   devcount      TINYINT UNSIGNED NOT NULL,
   INDEX devcount (dmid,classid,devcount)
)"
}

sub TABLE_tempfile {
    "CREATE TABLE tempfile (
   fid          INT UNSIGNED NOT NULL AUTO_INCREMENT,
   PRIMARY KEY  (fid),

   createtime   INT UNSIGNED NOT NULL,
   classid      TINYINT UNSIGNED NOT NULL,
   dmid          SMALLINT UNSIGNED NOT NULL,
   dkey           VARCHAR(255),
   devids       VARCHAR(60)
)"
}

# files marked for death when their key is overwritten.  then they get a new
# fid, but since the old row (with the old fid) had to be deleted immediately,
# we need a place to store the fid so an async job can delete the file from
# all devices.
sub TABLE_file_to_delete {
    "CREATE TABLE file_to_delete (
   fid  INT UNSIGNED NOT NULL,
   PRIMARY KEY (fid)
)"
}

# if the replicator notices that a fid has no sources, that file gets inserted
# into the unreachable_fids table.  it is up to the application to actually
# handle fids stored in this table.
sub TABLE_unreachable_fids {
    "CREATE TABLE unreachable_fids (
   fid        INT UNSIGNED NOT NULL,
   lastupdate INT UNSIGNED NOT NULL,
   PRIMARY KEY (fid),
   INDEX (lastupdate)
)"
}

# what files are on what devices?  (most likely physical devices,
# as logical devices of RAID arrays would be costly, and mogilefs
# already handles redundancy)
#
# the devid index lets us answer "What files were on this now-dead disk?"
sub TABLE_file_on {
    "CREATE TABLE file_on (
   fid          INT UNSIGNED NOT NULL,
   devid        MEDIUMINT UNSIGNED NOT NULL,
   PRIMARY KEY (fid, devid),
   INDEX (devid)
)"
}

# if application or framework detects an error in one of the duplicate files
# for whatever reason, it can register its complaint and the framework
# will do some verifications and fix things up w/ an async job
# MAYBE: let application tell us the SHA1/MD5 of the file for us to check
#        on the other devices?
sub TABLE_file_on_corrupt {
    "CREATE TABLE file_on_corrupt (
   fid          INT UNSIGNED NOT NULL,
   devid        MEDIUMINT UNSIGNED NOT NULL,
   PRIMARY KEY (fid, devid)
)"
}

# hosts (which contain devices...)
sub TABLE_host {
    "CREATE TABLE host (
   hostid     MEDIUMINT UNSIGNED NOT NULL PRIMARY KEY,

   status     ENUM('alive','dead','down'),
   http_port  MEDIUMINT UNSIGNED DEFAULT 7500,
   http_get_port MEDIUMINT UNSIGNED,

   hostname   VARCHAR(40),
   hostip     VARCHAR(15),
   altip      VARCHAR(15),
   altmask    VARCHAR(18),
   UNIQUE     (hostname),
   UNIQUE     (hostip),
   UNIQUE     (altip)
)"
}

# disks...
sub TABLE_device {
    "CREATE TABLE device (
   devid   MEDIUMINT UNSIGNED NOT NULL,
   hostid     MEDIUMINT UNSIGNED NOT NULL,

   status  ENUM('alive','dead','down'),
   weight  MEDIUMINT DEFAULT 100,

   mb_total   MEDIUMINT UNSIGNED,
   mb_used    MEDIUMINT UNSIGNED,
   mb_asof    INT UNSIGNED,
   PRIMARY KEY (devid),
   INDEX   (status)
)"
}

sub TABLE_server_settings {
    "CREATE TABLE server_settings (
   field   VARCHAR(50) PRIMARY KEY,
   value   VARCHAR(255))"
}

sub TABLE_file_to_replicate {
    # nexttry is time to try to replicate it next.
    #   0 means immediate.  it's only on one host.
    #   1 means lower priority.  it's on 2+ but isn't happy where it's at.
    #   unixtimestamp means at/after that time.  some previous error occurred.
    # fromdevid, if not null, means which devid we should replicate from.  perhaps it's the only non-corrupt one.  otherwise, wherever.
    # failcount.  how many times we've failed, just for doing backoff of nexttry.
    # flags.  reserved for future use.
    "CREATE TABLE file_to_replicate (
   fid        INT UNSIGNED NOT NULL PRIMARY KEY,
   nexttry    INT UNSIGNED NOT NULL,
   INDEX (nexttry),
   fromdevid  INT UNSIGNED,
   failcount  TINYINT UNSIGNED NOT NULL DEFAULT 0,
   flags      SMALLINT UNSIGNED NOT NULL DEFAULT 0
   )"
}

sub TABLE_file_to_delete_later {
    "CREATE TABLE file_to_delete_later (
   fid  INT UNSIGNED NOT NULL PRIMARY KEY,
   delafter INT UNSIGNED NOT NULL,
   INDEX (delafter)
)"
}

# these five only necessary for MySQL, since no other database existed
# before, so they can just create the tables correctly to begin with.
# in the future, there might be new alters that non-MySQL databases
# will have to implement.
sub upgrade_add_host_getport { 1 }
sub upgrade_add_host_altip { 1 }
sub upgrade_add_device_asof { 1 }
sub upgrade_add_device_weight { 1 }
sub upgrade_add_device_readonly { 1 }

# return true if deleted, 0 if didn't exist, exception if error
sub delete_host {
    my ($self, $hostid) = @_;
    return $self->dbh->do("DELETE FROM host WHERE hostid = ?", undef, $hostid);
}

# return true if deleted, 0 if didn't exist, exception if error
sub delete_domain {
    my ($self, $dmid) = @_;
    return $self->dbh->do("DELETE FROM domain WHERE dmid = ?", undef, $dmid);
}

sub domain_has_files {
    my ($self, $dmid) = @_;
    my $has_a_fid = $self->dbh->selectrow_array('SELECT fid FROM file WHERE dmid = ? LIMIT 1',
                                                undef, $dmid);
    return $has_a_fid ? 1 : 0;
}

sub class_has_files {
    my ($self, $dmid, $clid) = @_;
    my $has_a_fid = $self->dbh->selectrow_array('SELECT fid FROM file WHERE dmid = ? AND classid = ? LIMIT 1',
                                                undef, $dmid, $clid);
    return $has_a_fid ? 1 : 0;
}

# return new classid on success (non-zero integer), die on failure
# throw 'dup' on duplicate name
sub create_class {
    my ($self, $dmid, $classname) = @_;
    die "UNIMPLEMENTED";
}

# return 1 on success, throw "dup" on duplicate name error, die otherwise
sub update_class_name {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(dmid classid classname)], @_);
    my $rv = eval {
        $self->dbh->do("UPDATE class SET classname=? WHERE dmid=? AND classid=?",
                       undef, $arg{classname}, $arg{dmid}, $arg{classid});
    };
    throw("dup") if $self->was_duplicate_error;
    $self->condthrow;
    return 1;
}

# return 1 on success, die otherwise
sub update_class_mindevcount {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(dmid classid mindevcount)], @_);
    $self->dbh->do("UPDATE class SET mindevcount=? WHERE dmid=? AND classid=?",
                   undef, $arg{mindevcount}, $arg{dmid}, $arg{classid});
    $self->condthrow;
    return 1;
}

sub nfiles_with_dmid_classid_devcount {
    my ($self, $dmid, $classid, $devcount) = @_;
    return $self->dbh->selectrow_array('SELECT COUNT(*) FROM file WHERE dmid = ? AND classid = ? AND devcount = ?',
                                       undef, $dmid, $classid, $devcount);
}

sub set_server_setting {
    my ($self, $key, $val) = @_;
    my $dbh = $self->dbh;

    if (defined $val) {
        $dbh->do("REPLACE INTO server_settings (field, value) VALUES (?, ?)", undef, $key, $val);
    } else {
        $dbh->do("DELETE FROM server_settings WHERE field=?", undef, $key);
    }

    die "Error updating 'server_settings': " . $dbh->errstr if $dbh->err;
    return 1;
}

sub server_setting {
    my ($self, $key) = @_;
    return $self->dbh->selectrow_array("SELECT value FROM server_settings WHERE field=?",
                                       undef, $key);
}

# register a tempfile and return the fidid, which should be allocated
# using autoincrement/sequences if the passed in fid is undef.  however,
# if fid is passed in, that value should be used and returned.
#
# return -1 if the fid is already in use.
# return undef or 0 on any other error.
#
sub register_tempfile {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(fid dmid key classid devids)], @_);

    die "NOT IMPLEMENTED";
}

# return hashref of row containing columns "fid, dmid, dkey, length,
# classid, devcount" provided a $dmid and $key (dkey).  or undef if no
# row.
sub file_row_from_dmid_key {
    my ($self, $dmid, $key) = @_;
    return $self->dbh->selectrow_hashref("SELECT fid, dmid, dkey, length, classid, devcount ".
                                         "FROM file WHERE dmid=? AND dkey=?",
                                         undef, $dmid, $key);
}

# return hashref of row containing columns "fid, dmid, dkey, length,
# classid, devcount" provided a $dmid and $key (dkey).  or undef if no
# row.
sub file_row_from_fidid {
    my ($self, $fidid) = @_;
    return $self->dbh->selectrow_hashref("SELECT fid, dmid, dkey, length, classid, devcount ".
                                         "FROM file WHERE fid=?",
                                         undef, $fidid);
}

# return array of devids that a fidid is on
sub fid_devids {
    my ($self, $fidid) = @_;
    return @{ $self->dbh->selectcol_arrayref("SELECT devid FROM file_on WHERE fid=?",
                                             undef, $fidid) || [] };
}

# return hashref of columns classid, dmid, dkey, given a $fidid, or return undef
sub tempfile_row_from_fid {
    my ($self, $fidid) = @_;
    return $self->dbh->selectrow_hashref("SELECT classid, dmid, dkey ".
                                         "FROM tempfile WHERE fid=?",
                                         undef, $fidid);
}

# return 1 on success, throw "dup" on duplicate devid or throws other error on failure
sub create_device {
    my ($self, $devid, $hostid, $status) = @_;
    my $rv = $self->conddup(sub {
        $self->dbh->do("INSERT INTO device SET devid=?, hostid=?, status=?", undef,
                       $devid, $hostid, $status);
    });
    $self->condthrow;
    die "error making device $devid\n" unless $rv > 0;
    return 1;
}

sub update_device_usage {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(mb_total mb_used devid)], @_);
    $self->dbh->do("UPDATE device SET mb_total = ?, mb_used = ?, mb_asof = UNIX_TIMESTAMP() " .
                   "WHERE devid = ?", undef, $arg{mb_total}, $arg{mb_used}, $arg{devid});
    $self->condthrow;
}

sub mark_fidid_unreachable {
    my ($self, $fidid) = @_;
    $self->dbh->do("REPLACE INTO unreachable_fids VALUES (?, UNIX_TIMESTAMP())",
                   undef, $fidid);
}

sub set_device_weight {
    my ($self, $devid, $weight) = @_;
    $self->dbh->do('UPDATE device SET weight = ? WHERE devid = ?', undef, $weight, $devid);
    $self->condthrow;
}

sub set_device_state {
    my ($self, $devid, $state) = @_;
    $self->dbh->do('UPDATE device SET status = ? WHERE devid = ?', undef, $state, $devid);
    $self->condthrow;
}

sub delete_class {
    my ($self, $dmid, $cid) = @_;
    $self->dbh->do("DELETE FROM class WHERE dmid = ? AND classid = ?", undef, $dmid, $cid);
    $self->condthrow;
}

sub delete_fidid {
    my ($self, $fidid) = @_;
    $self->dbh->do("DELETE FROM file WHERE fid=?", undef, $fidid);
    $self->condthrow;
    $self->dbh->do("DELETE FROM tempfile WHERE fid=?", undef, $fidid);
    $self->condthrow;
    $self->dbh->do("REPLACE INTO file_to_delete SET fid=?", undef, $fidid);
    $self->condthrow;
}

sub delete_tempfile_row {
    my ($self, $fidid) = @_;
    $self->dbh->do("DELETE FROM tempfile WHERE fid=?", undef, $fidid);
    $self->condthrow;
}

sub replace_into_file {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(fidid dmid key length classid)], @_);
    $self->dbh->do("REPLACE INTO file ".
                   "SET ".
                   "  fid=?, dmid=?, dkey=?, length=?, ".
                   "  classid=?, devcount=0", undef,
                   @arg{'fidid', 'dmid', 'key', 'length', 'classid'});
    $self->condthrow;
}

# returns 1 on success, 0 on duplicate key error, dies on exception
sub rename_file {
    my ($self, $fidid, $to_key) = @_;
    die "UNIMPLEMENTED";
}

# returns a hash of domains. Key is namespace, value is dmid.
sub get_all_domains {
    my ($self) = @_;
    my $domains = $self->dbh->selectall_arrayref('SELECT namespace, dmid FROM domain');
    return map { ($_->[0], $_->[1]) } @{$domains || []};
}

# returns an array of hashrefs, one hashref per row in the 'class' table
sub get_all_classes {
    my ($self) = @_;
    my (@ret, $row);
    my $sth = $self->dbh->prepare("SELECT dmid, classid, classname, mindevcount FROM class");
    $sth->execute;
    push @ret, $row while $row = $sth->fetchrow_hashref;
    return @ret;
}

# add a record of fidid existing on devid
# returns 1 on success, 0 on duplicate
sub add_fidid_to_devid {
    my ($self, $fidid, $devid) = @_;
    my $rv = $self->dowell($self->ignore_replace . " INTO file_on (fid, devid) VALUES (?,?)",
                           undef, $fidid, $devid);
    return 1 if $rv > 0;
    return 0;
}

# remove a record of fidid existing on devid
# returns 1 on success, 0 if not there anyway
sub remove_fidid_from_devid {
    my ($self, $fidid, $devid) = @_;
    my $rv = $self->dbh->do("DELETE FROM file_on WHERE fid=? AND devid=?",
                            undef, $fidid, $devid);
    $self->condthrow;
    return $rv;
}

# get all hosts from database, returns them as list of hashrefs, hashrefs being the row contents.
sub get_all_hosts {
    my ($self) = @_;
    my $sth = $self->dbh->prepare("SELECT /*!40000 SQL_CACHE */ hostid, status, hostname, " .
                                  "hostip, http_port, http_get_port, altip, altmask FROM host");
    $sth->execute;
    my @ret;
    while (my $row = $sth->fetchrow_hashref) {
        push @ret, $row;
    }
    return @ret;
}

# get all devices from database, returns them as list of hashrefs, hashrefs being the row contents.
sub get_all_devices {
    my ($self) = @_;
    my $sth = $self->dbh->prepare("SELECT /*!40000 SQL_CACHE */ devid, hostid, mb_total, " .
                                  "mb_used, mb_asof, status, weight FROM device");
    $self->condthrow;
    $sth->execute;
    my @return;
    while (my $row = $sth->fetchrow_hashref) {
        push @return, $row;
    }
    return @return;
}

# update the device count for a given fidid
sub update_devcount {
    my ($self, $fidid) = @_;
    my $dbh = $self->dbh;
    my $ct = $dbh->selectrow_array("SELECT COUNT(*) FROM file_on WHERE fid=?",
                                   undef, $fidid);

    $dbh->do("UPDATE file SET devcount=? WHERE fid=?", undef,
              $ct, $fidid);

    return 1;
}

# enqueue a fidid for replication, from a specific deviceid (can be undef), in a given number of seconds.
sub enqueue_for_replication {
    my ($self, $fidid, $fromdevid, $in) = @_;
    die "UNIMPLEMENTED";
}

# takes two arguments, devid and limit, both required. returns an arrayref of fidids.
sub get_fidids_by_device {
    my ($self, $devid, $limit) = @_;

    my $dbh = $self->dbh;
    my $fidids = $dbh->selectcol_arrayref("SELECT fid FROM file_on WHERE devid = ? LIMIT $limit",
                                          undef, $devid);
    die "Error selecting jobs to reap: " . $dbh->errstr if $dbh->err;
    return $fidids;
}

# reschedule all deferred replication, return number rescheduled
sub replicate_now {
    my ($self) = @_;
    die "UNIMPLEMENTED";
}

# creates a new domain, given a domain namespace string.  return the dmid on success,
# throw 'dup' on duplicate name.
sub create_domain {
    my ($self, $name) = @_;
    die "UNIMPLEMENTED";
}

sub update_host_property {
    my ($self, $hostid, $col, $val) = @_;
    $self->conddup(sub {
        $self->dbh->do("UPDATE host SET $col=? WHERE hostid=?", undef, $val, $hostid);
    });
    return 1;
}

# return ne hostid, or throw 'dup' on error.
# NOTE: you need to put them into the initial 'down' state.
sub create_host {
    my ($self, $hostname, $ip) = @_;
    my $dbh = $self->dbh;
    # racy! lazy. no, better: portable! how often does this happen? :)
    my $hid = ($dbh->selectrow_array('SELECT MAX(hostid) FROM host') || 0) + 1;
    my $rv = $self->conddup(sub {
        $dbh->do("INSERT INTO host (hostid, hostname, hostip, status) ".
                 "VALUES (?, ?, ?, 'down')",
                 undef, $hid, $hostname, $ip);
    });
    return $hid if $rv;
    die "db failure";
}

# return array of row hashrefs containing columns: (fid, fromdevid,
# failcount, flags, nexttry)
sub files_to_replicate {
    my ($self, $limit) = @_;
    my $to_repl_map = $self->dbh->selectall_hashref(qq{
        SELECT fid, fromdevid, failcount, flags, nexttry
        FROM file_to_replicate
        WHERE nexttry <= UNIX_TIMESTAMP()
        ORDER BY nexttry
        LIMIT $limit
    }, "fid") or return ();
    return values %$to_repl_map;
}

# although it's safe to have multiple tracker hosts and/or processes
# replicating the same file, around, it's inefficient CPU/time-wise,
# and it's also possible they pick different places and waste disk.
# so the replicator asks the store interface when it's about to start
# and when it's done replicating a fidid, so you can do something smart
# and tell it not to.
sub should_begin_replicating_fidid {
    my ($self, $fidid) = @_;
    warn("Inefficient implementation of should_begin_replicating_fidid() in $self!\n");
    1;
}

# called when replicator is done replicating a fid, so you can cleanup whatever
# you did in 'should_begin_replicating_fidid' above.
sub note_done_replicating {
    my ($self, $fidid) = @_;
}

sub delete_fid_from_file_to_replicate {
    my ($self, $fidid) = @_;
    $self->dbh->do("DELETE FROM file_to_replicate WHERE fid=?", undef, $fidid);
}

sub reschedule_file_to_replicate_absolute {
    my ($self, $fid, $abstime) = @_;
    $self->dbh->do("UPDATE file_to_replicate SET nexttry = ?, failcount = failcount + 1 WHERE fid = ?",
                   undef, $abstime, $fid);
}

sub reschedule_file_to_replicate_relative {
    my ($self, $fid, $in_n_secs) = @_;
    die "UNIMPLEMENTED.  (see MySQL subclass)";
}

# Given a dmid prefix after and limit, return an arrayref of dkey from the file
# table.
sub get_keys_like {
    my ($self, $dmid, $prefix, $after, $limit) = @_;
    # fix the input... prefix always ends with a % so that it works
    # in a LIKE call, and after is either blank or something
    $prefix ||= '';
    $prefix .= '%';
    $after ||= '';

    # now select out our keys
    return $self->dbh->selectcol_arrayref
        ('SELECT dkey FROM file WHERE dmid = ? AND dkey LIKE ? AND dkey > ? ' .
         "ORDER BY dkey LIMIT $limit", undef, $dmid, $prefix, $after);
}

# return arrayref of all tempfile rows (themselves also arrayrefs, of [$fidid, $devids])
# that were created $secs_ago seconds ago or older.
sub old_tempfiles {
    my ($self, $secs_old) = @_;
    return $self->dbh->selectall_arrayref("SELECT fid, devids FROM tempfile " .
                                          "WHERE createtime < UNIX_TIMESTAMP() - $secs_old LIMIT 50");
}

# given an array of MogileFS::DevFID objects, mass-insert them all
# into file_on (ignoring if they're already present)
sub mass_insert_file_on {
    my ($self, @devfids) = @_;
    my @qmarks = map { "(?,?)" } @devfids;
    my @binds  = map { $_->fidid, $_->devid } @devfids;

    $self->dowell($self->ignore_replace . " INTO file_on (fid, devid) VALUES " . join(',', @qmarks), undef, @binds);
    return 1;
}

sub set_schema_vesion {
    my ($self, $ver) = @_;
    $self->set_server_setting("schema_version", int($ver));
}

1;

__END__

=head1 NAME

MogileFS::Store - data storage provider.  base class.

=head1 ABOUT

MogileFS aims to be database-independent (though currently as of late
2006 only works with MySQL).  In the future, the server will create a
singleton instance of type "MogileFS::Store", like
L<MogileFS::Store::MySQL>, and all database interaction will be
through it.

=head1 SEE ALSO

L<MogileFS::Store::MySQL>


