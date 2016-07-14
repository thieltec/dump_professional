#!/usr/bin/perl
# Dumping MySQL Schemata

# MODULE
use strict;
use DBI;
use DBI qw(:sql_types);
use English;
use Encode;
use Time::HiRes qw(gettimeofday);    # fuer eine genaue Zeiterfassung
use Getopt::Long;
use Log::Log4perl qw(:easy);
use POSIX ":sys_wait_h";
use Fcntl 'LOCK_EX', 'LOCK_NB';      # keine doppelten Prozesse
use feature 'state';

#------------------------------------------------------------------------------
# Global
#------------------------------------------------------------------------------
my $configurationfile = "dump_professional.conf";
my $optionfile        = "dump_professional.opt";

my $systemvariables;
my $character_set_server;

#------------------------------------------------------------------------------
# GetOptions
#------------------------------------------------------------------------------

# lowest options
my $opt;

# PROGRAM DUMP OPTIONS (DEFAULTS)
$opt->{mode}  		= 'full';		# full|meta|data|tables|sp|triggers|routines|events
$opt->{scope} 		= 'backup';		# backup|ansi|replication|migrate
$opt->{info}		= 'default';	# 0: info on/off
$opt->{add_drop}    = 0;			# Drop Objects 0|1
$opt->{performance} = 'innodb';		# innodb|myisam|mixed

$opt->{area} 		= 'use';		# use|single|whole
$opt->{schemata};					# which schemata?

$opt->{all}      	= 1;
$opt->{position} 	= 1;			# Binlog Position 0|1
$opt->{logfile}  	= "dump_professional.log";    # Log this Process
$opt->{loglevel} 	= 'INFO';		# Loglevel
$opt->{run}      	= 1;			#
$opt->{path}     	= '/tmp';		#
$opt->{file};
$opt->{compression} = 'none';		# none|lzo|gzip
$opt->{with_date}   = 1;

# CONNECTION
$opt->{basedir};
$opt->{user};
$opt->{password};
$opt->{host};
$opt->{port};
$opt->{'socket'};
$opt->{mycnf_client};

# middle options
my $cfg		= OptionFile::options_get( $optionfile, 'option' );
foreach my $option (keys %$cfg){
	$opt->{$option} = $cfg->{$option};
}

my $config	= new ConfigFile($configurationfile);

my $is_help = 0;

# highest options
# ---------------

GetOptions(
	'mode:s'   => \$opt->{mode},
	'add-drop' => \$opt->{add_drop},
	'scope'    => \$opt->{scope},

	'area:s'     => \$opt->{area},
	'schemata:s' => \$opt->{schemata},
	'all'        => \$opt->{all},

	'logfile:s' => \$opt->{logfile},
	'loglevel'  => \$opt->{loglevel},
	'run'       => \$opt->{run},

	'path'     => \$opt->{path},
	'file'     => \$opt->{file},
	'compress' => \$opt->{compression},

	'basedir:s'      => \$opt->{basedir},
	'user:s'         => \$opt->{user},
	'password:s'     => \$opt->{password},
	'host:s'         => \$opt->{host},
	'port:s'         => \$opt->{port},
	'socket:s'       => \$opt->{socket},
	'mycnf_client:s' => \$opt->{mycnf_client},
	'help|?'         => \$is_help
);

# Help
if ($is_help) {
	usage();
	exit 0;
}

# Logger
logger_init( "INFO", $opt->{logfile} );
my $log = Log::Log4perl::get_logger("DumpProfessional");

# TODO Child Process
# TODO Status Variables

#------------------------------------------------------------------------------
# CONNECTION
#------------------------------------------------------------------------------
my $dbh;
if ( defined( $opt->{host} ) ) {
	$dbh =
	  connection::mysql_connect( $opt->{user}, $opt->{password}, $opt->{host},
		$opt->{port} )
	  or die "Cannot connect.\n";
}
elsif ( defined $opt->{mycnf_client} ) {
	$dbh = connection::mysql_connect_mycnf( $opt->{mycnf_client} )
	  or die "Cannot connect.\n";
}
elsif ( defined $optionfile ) {
	$dbh = connection::mysql_connect_mycnf( $optionfile, 'client' )
	  or die "Cannot connect.\n";
}
else {
	die "No connection possible.";
}

#------------------------------------------------------------------------------
# ENVIRONMENT PARAMETERS FOR OPTIMIZING
#------------------------------------------------------------------------------
# ENVIRONMENT
$systemvariables->{'original'} =
  sysenv::systemvariables_global_get();    # Original
$systemvariables->{'actual'} =
  sysenv::systemvariables_global_get();    # For Dumping

# Special Variables
# CHARSET
$character_set_server =
  $systemvariables->{'original'}->{'character_set_server'};

#------------------------------------------------------------------------------
# DUMP MODI
#------------------------------------------------------------------------------
# TODO %dumpconfig noch gebraucht?
my %dumpconfig;

my $config = new ConfigFile($configurationfile);
$config->config_default_set('mysqldump');

# A. PART {full|meta|data|triggers|routines}
$config->segment_set( 'part', $opt->{mode} );

# B. DROP {0|1}
$config->segment_set( 'drop', $opt->{add_drop} );

# C. SCOPE {backup|migration|replication|ansi}
$config->segment_set( 'ddl',         $opt->{scope} );
$config->segment_set( 'dml',         $opt->{scope} );
$config->segment_set( 'replication', $opt->{scope} );

# D. INFO
$config->segment_set( 'info', $opt->{info} );

# E. PERFORMANCE
$config->segment_set( 'performance', $opt->{performance} );

foreach my $segment ( @{ $config->{_segments} } ) {

	# Only use options that are available for this version of mysqldump
	dumpoptions_versionfilter( $config->{$segment} );
}

%dumpconfig = %{ $config->{_default} };

#------------------------------------------------------------------------------
# SCHEMATA
#------------------------------------------------------------------------------
# SCHEMATA with Charset
my @schematainfo;
if ( $opt->{all} ) {

	# dump all schemata
	@schematainfo = schemata_all_get();
}
elsif ( defined $opt->{schemata} ) {

	# dump select schemata
	@schematainfo = schemata_selected_get( $opt->{schemata} );
}
else {
	print "No schemata are selected.\n";
	exit(1);
}

#------------------------------------------------------------------------------
# BUILDING THE DUMP COMMAND
#------------------------------------------------------------------------------
my @commands;
my $dumpcommand;

# DUMP OPTIMIZER
$dumpconfig{'compress'} =
  optimize::option_compress( $opt->{host} );    # connection compress/not file
$dumpconfig{'ssl'} =
  optimize::option_ssl( $opt->{host},
	$systemvariables->{'original'}->{'have_ssl'},
	$dumpconfig{'ssl'} );

# DUMP CONNECTION
#$dumpcommand->{'connection'} = dmpcmd::mysqldump_connection_get();
$dumpcommand->{'connection'} = dmpcmd::mysqldump_connection_file();

# DUMP COMMANDS
if ( $opt->{area} eq "whole" ) {

	# dump all at once
	my $dcommand =
	  dmpcmd::dumpcommand_whole_set( $systemvariables->{'original'} );
	my $command = dmpcmd::dumpcommand_get($dcommand);

	push( @commands, $command );
}
elsif ( $opt->{area} eq "use" or $opt->{area} eq "single" ) {

	# dump per schema
	foreach my $rs (@schematainfo) {
		my $dcommand = dmpcmd::dumpcommand_schema_set($rs);
		my $command  = dmpcmd::dumpcommand_get($dcommand);

		push( @commands, $command );
	}
}
else {
	print STDOUT "No --area selected\n";
}

#------------------------------------------------------------------------------
# DUMP RUN
#------------------------------------------------------------------------------
# Anpassung fuers Dumpen
if ( $opt->{run} ) {
	sysenv::systemvariables_global_dump_set();

	# User Dump
	# TODO: ANSI MODE
	account::user_dump( $opt->{path}, $opt->{compression},
		$config->{ddl}->{compatible} );
	foreach my $command (@commands) {
		if ( defined( $opt->{basedir} ) ) {
			$command = $opt->{basedir} . "/" . $command;
		}

		# Log Command
		$log->info($command);

		# Run Command
		my $ret = dumpcommand_run($command);
		print "dump ".$ret."\n";
	}
	sysenv::systemvariables_global_reset( $systemvariables->{'original'} );
}
else {
	foreach my $command (@commands) {
		if ( defined( $opt->{basedir} ) ) {
			$command = $opt->{basedir} . "/" . $command;
		}

		# Log Command
		$log->info($command);
	}

}
$dbh->disconnect;
1;

#------------------------------------------------------------------------------
# BEGIN/END
#------------------------------------------------------------------------------
sub END {

	# Clean Up
	if ( defined $dbh ) {
		sysenv::systemvariables_global_reset( $systemvariables->{'original'} );
		$dbh->disconnect;
	}

}

#------------------------------------------------------------------------------
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# USAGE / HELP
#------------------------------------------------------------------------------
sub usage() {

	my %scriptinfo;
	$scriptinfo{'version'}      = "1.9.2 Beta";
	$scriptinfo{'date'}         = "2014-04-28";
	$scriptinfo{'author'}       = "Holger Thiel (OCP)";
	$scriptinfo{'abbreviation'} = "hoth";
	$scriptinfo{'comment'}      = "\"Trust Me. I Know What I Am Doing.\"";
	$scriptinfo{'licence'}      = "GPLv3";

	print <<HELP;
$0 --mode={full|meta|data|sp|events|triggers|routines} --area={use|single|whole} <--schemata=<schemata>|--all> 
 [--compress=<gzip|lzo|none>] [--add-drop] --path=<FILE> [--run] [--lzo] [--socket=<SOCKET> [--user=<USER> --password=<PASSWORD>]  
--run     : run the dump
--compress: use compression 
--mode    : define objects and data
--area    : use/single - dump each schema for itself, single with 'CREATE SCHEMA'
            whole - dump as one block
--schemata: define schemata to dump

Version $scriptinfo{'version'}($scriptinfo{'date'})
Licence: $scriptinfo{'licence'}, Author: $scriptinfo{'author'}
$scriptinfo{'comment'}
HELP
	print "\n";
	# middle options
	my $cfg		= OptionFile::options_get( $optionfile, 'option' );
	foreach my $option (keys %$cfg){
		print $option."=".$cfg->{$option}."\n";
	}	
}

#------------------------------------------------------------------------------
# DUMP RUN
#------------------------------------------------------------------------------
sub dumpcommand_run() {
	my ($command) = @_;

	my %timer;
	$log->info("Starting dump.");

	$timer{'start'} = time();
	my $ret = system($command);
	$timer{'stop'} = time();

	$log->info( "Stopping dump. Duration: "
		  . ( $timer{'stop'} - $timer{'start'} )
		  . " s" );
		  
	return $ret;
}

sub dumpoptions_versionfilter($) {
	my ($segment) = @_;

	# Only use options that are available for this version of mysqldump

	my $mysqldump = "mysqldump";

	if ( defined $opt->{basedir} ) {
		$mysqldump = $opt->{basedir} . "/mysqldump";
	}

	# Get options
	my @output = `$mysqldump --help`;

	foreach my $option ( keys %$segment ) {
		
		#print $option."\n";
		my $not_found = 1;
		foreach my $line (@output) {
			if ( $line =~ /^.*--($option).*$/ ) {

				#print "found '$option' $line";
				$not_found = 0;
				last;
			}
		}

		# Option Not found.
		if ($not_found) {
			 $log->warn("Option '$option' is not available in this binary of mysqldump and is skipped.");
			delete( $segment->{$option} );
		}
	}
}

#------------------------------------------------------------------------------
# ENVIRONMENT
#------------------------------------------------------------------------------
sub mysqld_serverversion_get() {
	my $versionvalue;

	# Teilt einer MySQL-Version einen Integerwert zu.
	if ( !defined($versionvalue) ) {
		$dbh->{'mysql_serverinfo'} =~
		  /^([0-9]{1})\.([0-9]{1,2})\.([0-9]{1,3}).*$/;
		$versionvalue = 10000 * $1 + 100 * $2 + $3;
	}

	return $versionvalue;
}

sub mysqldump_version_get() {
	my $versionvalue;

	# Teilt einer MySQL-Version einen Integerwert zu.

	# mysqldump  Ver 10.13 Distrib 5.5.8, for linux2.6 (x86_64)
	if ( !defined($versionvalue) ) {
		$dbh->{'mysql_serverinfo'} =~
		  /^mysqldump  Ver.*Distrib ([0-9]{1})\.([0-9]{1,2})\.([0-9]{1,3}).*$/;
		$versionvalue = 10000 * $1 + 100 * $2 + $3;
	}

	return $versionvalue;
}

#------------------------------------------------------------------------------
# CONFIG PART
#------------------------------------------------------------------------------
sub config_binlogposition_set() {
	my $masterdata = shift;

	if ( $masterdata == 1 ) {
		$dumpconfig{'master-data'} = 1;
	}
	elsif ( defined $dumpconfig{'master-data'} ) {

		# NOP
	}
	else {
		$dumpconfig{'master-data'} = 2;
	}
}

sub schema_characterset_get() {
	my $schema = shift;

	my $rs = $dbh->selectrow_hashref(
"SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=?",
		undef, ($schema)
	);

	return $rs->{'DEFAULT_CHARACTER_SET_NAME'};
}

sub timestamp_get() {
	my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
	  localtime(time);
	$year = $year + 1900;
	$mon  = $mon + 1;
	if ( $mon < 10 ) {
		$mon = "0" . $mon;
	}
	if ( $mday < 10 ) {
		$mday = "0" . $mday;
	}
	if ( $hour < 10 ) {
		$hour = "0" . $hour;
	}
	if ( $min < 10 ) {
		$min = "0" . $min;
	}
	if ( $sec < 10 ) {
		$sec = "0" . $sec;
	}
	return ( $year . "" . $mon . "" . $mday . "T" . $hour . $min . $sec );
}

#------------------------------------------------------------------------------
# MySQL-Schemata
#------------------------------------------------------------------------------
sub schemata_all_get() {
	my $sth =
	  $dbh->prepare(
"SELECT SCHEMA_NAME,DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema')"
	  );

	$sth->execute();

	my @schemata;

	while ( my $rs = $sth->fetchrow_hashref ) {
		push( @schemata, $rs );
	}

	return @schemata;
}

sub schemata_selected_get() {
	my $str = shift;

	my @schemata = split( /,/, $str );

	my @schematainfo;
	my $sth =
	  $dbh->prepare(
"SELECT SCHEMA_NAME,DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=?"
	  );

	foreach my $schema (@schemata) {
		$sth->bind_param( 1, $schema, SQL_VARCHAR );

		$sth->execute();
		while ( my $rs = $sth->fetchrow_hashref ) {
			push( @schematainfo, $rs );
		}
	}
	return @schematainfo;
}

#------------------------------------------------------------------------------
# LOGGER
#------------------------------------------------------------------------------
sub logger_init($$) {
	my ( $loglevel, $logfile ) = @_;

	use Log::Log4perl;

	#    %c Category of the logging event.
	#    %C Fully qualified package (or class) name of the caller
	#    %d Current date in yyyy/MM/dd hh:mm:ss format
	#    %F File where the logging event occurred
	#    %H Hostname (if Sys::Hostname is available)
	#    %l Fully qualified name of the calling method followed by the
	#       callers source the file name and line number between
	#       parentheses.
	#    %L Line number within the file where the log statement was issued
	#    %m The message to be logged
	#    %m{chomp} The message to be logged, stripped off a trailing newline
	#    %M Method or function where the logging request was issued
	#    %n Newline (OS-independent)
	#    %p Priority of the logging event
	#    %P pid of the current process
	#    %r Number of milliseconds elapsed from program start to logging
	#       event
	#    %R Number of milliseconds elapsed from last logging event to
	#       current logging event
	#    %T A stack trace of functions called
	#    %x The topmost NDC (see below)
	#    %X{key} The entry 'key' of the MDC (see below)
	#    %% A literal percent (%) sign

	# Configuration in a string ...
	my $conf = q(
    log4perl.category.DumpProfessional                 = INFO, Logfile, Screen
    log4perl.appender.Logfile                          = Log::Log4perl::Appender::File
    log4perl.appender.Logfile.filename                 = dump_professional.log 
    log4perl.appender.Logfile.layout                   = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Logfile.layout.ConversionPattern = <%d{yyyy-MM-dd HH:mm:ss} %p> %m%n
    log4perl.appender.Screen                           = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr                    = 0
    log4perl.appender.Screen.layout                    = Log::Log4perl::Layout::SimpleLayout
  );

	# ... passed as a reference to init()
	Log::Log4perl::init( \$conf );
}

#------------------------------------------------------------------------------
# UNDO
#------------------------------------------------------------------------------
END {
	if ( defined $opt->{host} ) {
		sysenv::systemvariables_global_reset( $systemvariables->{'original'} );
	}
}

#------------------------------------------------------------------------------
# USER / GRANTEE
#------------------------------------------------------------------------------
package account;

use DBI;
use DBI qw(:sql_types);

sub account_by_grantee_get($) {
	my ($grantee) = @_;

	my $account;

	# Input: Grantee, Ouptut: Account (User, Host)
	if ( $grantee =~ /^'{1}(.*)'{1}\@'{1}(.*)'{1}/ ) {
		( $account->{'username'}, $account->{'host'} ) = ( $1, $2 );
	}
	elsif ( $grantee =~ /^"{1}(.*)"{1}\@"{1}(.*)"{1}/ ) {
		( $account->{'username'}, $account->{'host'} ) = ( $1, $2 );
	}
	elsif ( $grantee =~ /^`(.*)`\@`(.*)`/ ) {
		( $account->{'username'}, $account->{'host'} ) = ( $1, $2 );
	}
	elsif ( $grantee =~ /^(.*)\@(.*)/ ) {
		( $account->{'username'}, $account->{'host'} ) = ( $1, $2 );
	}

	return $account;
}

sub user_dump() {
	my ( $path, $compress, $sql_mode ) = @_;

	# timestamp on/off
	my $date;
	if ( $opt->{with_date} ) {
		$date = main::timestamp_get();
	}
	else {
		$date = "";
	}
	
	my $userfile = $path . "/"
	  . fileprefix_get( $systemvariables->{'original'} )
	  . "."
	  . $date
	  . ".mysqluser.sql"
	  . compression_suffix($compress);
	
	$log->info("Dump Users: ".$userfile);	  

	# Open Dump
	my $command = 
	    compression_command($compress) .$userfile;
	  
	$log->info($command);	  

	open( USERFILE,$command ) || die "can't open pipe to $command";
	print USERFILE "--\n-- User Dump 1.0.1\n-- " . main::timestamp_get() . "\n";

	# SQL Mode Set
	if ( lc($sql_mode) eq 'ansi' ) {

		# ANSI
		$dbh->do(
"SET \@OLD_USER_DUMP_SQL_MODE=\@\@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO,ANSI'"
		);
		print USERFILE
"/*!40101 SET \@OLD_USER_DUMP_SQL_MODE=\@\@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO,NO_AUTO_CREATE_USER,ANSI' */\n";
	}
	else {

		# ELSE
		$dbh->do(
"SET \@OLD_USER_DUMP_SQL_MODE=\@\@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO'"
		);
		print USERFILE
"/*!40101 SET \@OLD_USER_DUMP_SQL_MODE=\@\@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO,NO_AUTO_CREATE_USER' */\n";
	}

	# Get all Users from information_schema.USER_PRTIVILEGES
	my $sql =
"SELECT /*user_dump()*/ DISTINCT GRANTEE FROM USER_PRIVILEGES ORDER BY GRANTEE";
	my $sth = $dbh->prepare($sql);
	$sth->execute();

	while ( my $rs = $sth->fetchrow_hashref() ) {
		my $account = account_by_grantee_get( $rs->{'GRANTEE'} );

		print USERFILE "\n-- ACCOUNT '"
		  . $account->{'username'} . "'\@'"
		  . $account->{'host'} . "'\n";

		my $ret = create_user_get($account);

		foreach my $grant (@$ret) {
			print USERFILE $grant . ";\n";
		}
	}

	# Close Dump / clean up
	print USERFILE "\n/*!40101 SET SQL_MODE=\@OLD_USER_DUMP_SQL_MODE */\n";
	print USERFILE "--\n-- End Of User Dump\n--";
	close USERFILE;
	$sth->finish();
	$dbh->do("SET SQL_MODE=\@OLD_USER_DUMP_SQL_MODE");

}

sub create_user_get($) {
	my ($account) = @_;

	my $str =
	    "SHOW GRANTS FOR '"
	  . $account->{'username'} . "'\@'"
	  . $account->{'host'} . "'";
	my $sth = $dbh->prepare($str);
	$sth->execute();

	my @ret;

	#GRANT
	#    priv_type [(column_list)]
	#      [, priv_type [(column_list)]] ...
	#    ON [object_type] priv_level
	#    TO user_specification [, user_specification] ...
	#    [REQUIRE {NONE | ssl_option [[AND] ssl_option] ...}]
	#    [WITH with_option ...]

	while ( my $rs = $sth->fetchrow_arrayref() ) {
		my (
			$priv_type, $object_type, $ischema,
			$grantee,   $grant,       $passwordhash
		);

		if ( $rs->[0] =~
/^GRANT (.+) ON \*\.\* TO (\'$account->{'username'}\'\@\'$account->{'host'}\')$/
		  )
		{

			# Global Privileges without Password
			( $priv_type, $grantee ) = ( $1, $2 );

			my $str1 = "CREATE USER " . $grantee;
			push( @ret, $str1 );

			my $str2 = "GRANT $priv_type ON *.* TO " . $grantee;
			push( @ret, $str2 );
		}
		elsif ( $rs->[0] =~
/^GRANT (.+) ON \*\.\* TO (\'$account->{'username'}\'\@\'$account->{'host'}\') WITH GRANT OPTION$/
		  )
		{

			# Global Privileges without Password and with Grant Option
			( $priv_type, $grantee ) = ( $1, $2 );

			my $str1 = "CREATE USER " . $grantee;
			push( @ret, $str1 );

			my $str2 =
			  "GRANT $priv_type ON *.* TO " . $grantee . " WITH GRANT OPTION";
			push( @ret, $str2 );
		}
		elsif ( $rs->[0] =~
/^GRANT (.+) ON \*\.\* TO (\'$account->{'username'}\'\@\'$account->{'host'}\') (.*) WITH GRANT OPTION$/
		  )
		{

			# Global Privileges with Password and GRANT OPTION
			( $priv_type, $grantee, $passwordhash ) = ( $1, $2, $3 );
			my $str1 = "CREATE USER $grantee $passwordhash";
			push( @ret, $str1 );

			my $str2 = "GRANT $priv_type ON *.* TO $grantee WITH GRANT OPTION";
			push( @ret, $str2 );
		}
		elsif ( $rs->[0] =~
/^GRANT (.+) ON \*\.\* TO (\'$account->{'username'}\'\@\'$account->{'host'}\') (.*)$/
		  )
		{

			# Global Privileges with Password
			( $priv_type, $grantee, $passwordhash ) = ( $1, $2, $3 );
			my $str1 = "CREATE USER $grantee $passwordhash";
			push( @ret, $str1 );

			my $str2 = "GRANT $priv_type ON *.* TO $grantee";
			push( @ret, $str2 );
		}
		else {

			# Other Privileges
			push( @ret, $rs->[0] );
		}
	}
	return \@ret;
}

sub compression_command($) {
	my ($compression) = @_;

	my $command;

	if ( $compression eq 'gzip' ) {

		# GZip-Compression
		$command = "| gzip --fast --force > ";
	}
	elsif ( $compression eq 'lzo' ) {

		# LZO-Compression
		$command = "| lzop -cf > ";
	}
	elsif ( $compression eq 'none' or $compression eq 'none' or !defined $compression ) {

		# No File Compression
		$command = "> ";
	}
	else {
		die "Compression not available.";
	}

	return $command;
}

sub compression_suffix($) {
	my ($compression) = @_;

	my $command;

	if ( $compression eq 'gzip' ) {

		# GZip-Compression
		$command = ".gz";
	}
	elsif ( $compression eq 'lzo' ) {

		# LZO-Compression
		$command = ".lzo";
	}
	else {
		$command = "";
	}

	return $command;
}

sub fileprefix_get($) {
	my ($sysvar) = @_;

	# FILENAME
	if ( defined $sysvar->{'report_host'}
		and $sysvar->{'report_host'} ne '' )
	{
		$dumpcommand->{'fileprefix'} =
		  $sysvar->{'report_host'} . "_" . $sysvar->{'port'};
	}
	else {
		$dumpcommand->{'fileprefix'} =
		  $sysvar->{'hostname'} . "_" . $sysvar->{'port'};
	}
}
1;

#------------------------------------------------------------------------
# CONNECTION
#------------------------------------------------------------------------
package connection;

sub mysql_connect_mycnf($$) {
	my $configFile = shift;
	my $section    = shift;

	my $conn = mysql_connect_config_get( $configFile, $section );

	$opt->{user}     = $conn->{user};
	$opt->{password} = $conn->{password};
	$opt->{host}     = $conn->{host};
	$opt->{port}     = $conn->{port};

	if ( !defined $conn->{database} ) {
		$conn->{database} = "information_schema";
	}

	#my $extra = getConfig( $configFile, $section );

	# SSL-default is ON
	#	my $ssl = 1;
	#	if(defined $extra->{'mysql_ssl'}){
	#		$ssl = $extra->{'mysql_ssl'};
	#	};

	my $dsn =
"DBI:mysql:database=$conn->{database};host=$conn->{host};port=$conn->{port};mysql_ssl=1";

	# CONNECT
	my $dbh = DBI->connect( $dsn, $conn->{user}, $conn->{password} );

	# Auto-Reconnect
	#	if(defined $extra->{'mysql_auto_reconnect'}){
	#		$dbh->{'mysql_auto_reconnect'} = $extra->{'mysql_auto_reconnect'};
	#	}else{
	#		$dbh->{'mysql_auto_reconnect'} = 1;
	#	};

	# ANSI-MODE
	if ( defined $dbh ) {
		$dbh->{'mysql_auto_reconnect'} = 1;
		$dbh->do(
"SET SESSION sql_mode='REAL_AS_FLOAT,PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION'"
		);
	}

	#	# AutoCommit
	#	if(defined $extra->{'autocommit'}){
	#		$dbh->{'AutoCommit'} = $extra->{'AutoCommit'};
	#	};

	return $dbh;
}

sub mysql_connect_config_get($$) {
	my ( $configFile, $server ) = @_;

	# DBMS Connection Configuration

	# In your program
	use Config::Tiny;

	# Create a config
	my $Config = Config::Tiny->new;

	# Open the config
	$Config = Config::Tiny->read($configFile);

	# Reading properties
	my $obj;

	$obj->{host}     = $Config->{$server}->{host};
	$obj->{port}     = $Config->{$server}->{port};
	$obj->{database} = $Config->{$server}->{database};
	$obj->{user}     = $Config->{$server}->{user};
	$obj->{password} = $Config->{$server}->{password};

	return $obj;
}

sub mysql_connect() {
	my ( $user, $password, $host, $port, $database ) = @_;

	my $dbh = DBI->connect(
		"DBI:mysql:database=$database;host=$host;port=$port",
		$user,
		$password,
		{
			'RaiseError'           => 0,
			'AutoCommit'           => 0,
			'mysql_auto_reconnect' => 3
		}
	);
	$dbh->do("SET SESSION tx_isolation='READ-COMMITTED'");

	#$dbh->do("SET SESSION myisam_repair_threads=2");
	#$dbh->do("SET SESSION myisam_sort_buffer_size=134217728");
	$dbh->do("SET SESSION sql_mode='ANSI,TRADITIONAL,NO_ENGINE_SUBSTITUTION'");
	return $dbh;
}
1;

#------------------------------------------------------------------------------
# OPTION
#------------------------------------------------------------------------------
package OptionFile;

# Package for the Option File

sub options_get($$) {
	my ( $configFile, $segment ) = @_;

	# DBMS Connection Configuration

	# In your program
	use Config::Tiny;

	# Create a config
	my $Config = Config::Tiny->new;

	# Open the config
	$Config = Config::Tiny->read($configFile);

	# Reading properties
	my $obj = $Config->{$segment};

	return $obj;
}
1;

#------------------------------------------------------------------------------
# CONFIGURATION
#------------------------------------------------------------------------------
package ConfigFile;

# Package for the Configuration File

sub new {

	#constructor
	my ( $class, $configFile ) = @_;
	my $self = {
		_default    => undef,
		_configfile => $configFile,
		_segments   => []
	};
	bless $self, $class;

	return $self;
}

sub config_default_set() {
	my ( $self, $segment ) = @_;

	push( $self->{_segments}, '_default' );

	$self->{_default} = segment_get( $self, $segment );
}

sub segment_set($$$) {
	my ( $self, $topic, $topicvalue ) = @_;

	push( $self->{_segments}, $topic );

	$self->{$topic} = segment_load( $self, $topic, $topicvalue );
	segment_integrate( $self->{_default}, $self->{$topic} );
}

sub segment_load($$$) {
	my ( $self, $topic, $topicvalue ) = @_;

	# Get the Values for the Topic
	my $segment = $topic . '_' . $topicvalue;

	return ( segment_get( $self, $segment ) );
}

sub segment_integrate($$) {
	my ( $config_whole, $config_add ) = @_;

	# Integrate Config in another Config.
	foreach my $config_key ( sort keys %$config_add ) {
		$config_whole->{$config_key} = $config_add->{$config_key};
	}
}

sub segment_get($$) {
	my ( $self, $segment ) = @_;

	# Generic Routine for the Configuration

	# In your program
	use Config::Tiny;

	# Create a config
	my $Config = Config::Tiny->new;

	# Open the config
	$Config = Config::Tiny->read( $self->{_configfile} );

	# Reading properties
	my $obj = $Config->{$segment};

	return $obj;
}
1;

#------------------------------------------------------------------------------
# OPTIONS OPTIMIZER
#------------------------------------------------------------------------------
package optimize;

sub option_compress($) {
	my ($host) = @_;

	use Socket;

	# Determine if compression make sense
	my $address = inet_ntoa( scalar gethostbyname( $host || 'localhost' ) );

	my $ret;
	if ( $address eq '127.0.0.1' ) {
		$ret = 0;
	}
	else {
		$ret = 1;
	}

	return $ret;
}

sub option_ssl() {
	my ( $host, $have_ssl, $config_ssl ) = @_;

	use Socket;

	# Determine if compression make sense
	my $address = inet_ntoa( scalar gethostbyname( $host || 'localhost' ) );

	my $ret;
	if ( $address eq '127.0.0.1' ) {

		# No SSL for localhost / 127.0.0.1
		$ret = 0;
	}
	elsif ( ( uc($have_ssl) eq 'YES' ) ) {
		$ret = $config_ssl;
	}
	else {
		$ret = 1;
	}

	if ( !defined $ret ) {
		$ret = 0;
	}

	return $ret;
}
1;

#------------------------------------------------------------------------------
# DUMP COMMAND
#------------------------------------------------------------------------------
package dmpcmd;

sub mysqldump_options_get() {
	my $mysqldumpoptions = "";

	# OPTIONS
	foreach my $option ( sort keys %dumpconfig ) {
		if ( $dumpconfig{$option} eq "1" ) {
			$mysqldumpoptions = $mysqldumpoptions . "--" . $option . "=1 ";
		}
		elsif ( $dumpconfig{$option} eq "0" ) {
			$mysqldumpoptions = $mysqldumpoptions . "--" . $option . "=0 ";
		}
		elsif ( defined( $dumpconfig{$option} ) ) {
			$mysqldumpoptions =
			    $mysqldumpoptions . "--" . $option . "="
			  . $dumpconfig{$option} . " ";
		}
		else {

			# NOP
		}
	}

	return $mysqldumpoptions;
}

sub compression_command($) {
	my ($compression) = @_;

	my $command;

	if ( $compression eq 'gzip' ) {

		# GZip-Compression
		$command = "|gzip --fast --force > ";
	}
	elsif ( $compression eq 'lzo' ) {

		# LZO-Compression
		$command = "|lzop -cf > ";
	}
	else {
		$command = " > ";
	}

	return $command;
}

sub dumpcommand_get() {
	my ($dumpcommand) = @_;

	my $command;

	# 1. Connection
	# 2. Options
	# 3.
	# 4. Schemata

	$command =
	    "mysqldump "
	  . $dumpcommand->{'connection'}
	  . $dumpcommand->{'options'}
	  . $dumpcommand->{'with'}
	  . $dumpcommand->{'schemata'};

	# COMPRESSION
	if ( $opt->{compression} eq 'gzip' ) {

		# GZip-Compression
		$command = $command
		  . compression_command( $opt->{compression} )
		  . $opt->{path} . "/"
		  . $dumpcommand->{'fileprefix'}
		  . $dumpcommand->{'date'} . "."
		  . $opt->{mode} . ".sql" . ".gz";
	}
	elsif ( $opt->{compression} eq 'lzo' ) {

		# LZO-Compression
		$command = $command
		  . compression_command( $opt->{compression} )
		  . $opt->{path} . "/"
		  . $dumpcommand->{'fileprefix'}
		  . $dumpcommand->{'date'} . "."
		  . $opt->{mode} . ".sql" . ".lzo";
	}
	else {

		# No Compression
		$command = $command
		  . compression_command( $opt->{compression} )
		  . $opt->{path} . "/"
		  . $dumpcommand->{'fileprefix'}
		  . $dumpcommand->{'date'} . "."
		  . $opt->{mode} . ".sql";
	}

	return $command;
}

sub dumpcommand_whole_set($) {
	my ($sysvar) = @_;

	# FILENAME
	if ( defined $sysvar->{'report_host'}
		and $sysvar->{'report_host'} ne '' )
	{
		$dumpcommand->{'fileprefix'} =
		  $sysvar->{'report_host'} . "_" . $sysvar->{'port'};
	}
	else {
		$dumpcommand->{'fileprefix'} =
		  $sysvar->{'hostname'} . "_" . $sysvar->{'port'};
	}

	foreach my $rs (@schematainfo) {
		$dumpcommand->{'schemata'} =
		  $dumpcommand->{'schemata'} . $rs->{'SCHEMA_NAME'} . " ";
	}

	# CHARSET <=> SERVER CHARSET
	$dumpconfig{'default-character-set'} =
	  $systemvariables->{'original'}->{'character_set_server'};

	$dumpcommand->{'options'} = mysqldump_options_get();
	$dumpcommand->{'with'}    = "--databases ";

	return $dumpcommand;
}

sub dumpcommand_schema_set($) {
	my $rschema = shift;    # Schema with Charset

	my $dumpcommand;

	# mysqldump Connection
	$dumpcommand->{'connection'} = mysqldump_connection_file();

	# PER SCHEMA
	if ( $opt->{area} eq 'use' ) {
		$dumpcommand->{'with'} = " ";
	}
	elsif ( $opt->{area} eq 'single' ) {
		$dumpcommand->{'with'} = "--databases ";
	}
	else {
		$dumpcommand->{'with'} = "--databases ";
	}

	# timestamp on/off
	if ( $opt->{with_date} ) {
		$dumpcommand->{'date'} = "." . main::timestamp_get();
	}
	else {
		$dumpcommand->{'date'} = "";
	}

	# file <=> PFAD/SCHEMA.dmp
	$dumpcommand->{'schemata'}   = $rschema->{'SCHEMA_NAME'};
	$dumpcommand->{'fileprefix'} = $rschema->{'SCHEMA_NAME'};

	# CHARSET <=> SCHEMA CHARSET
	$dumpcommand->{'default-character-set'} =
	  $rschema->{'DEFAULT_CHARACTER_SET_NAME'};
	$dumpconfig{'default-character-set'} =
	  $rschema->{'DEFAULT_CHARACTER_SET_NAME'};
	$dumpcommand->{'options'} = mysqldump_options_get();
	$dumpconfig{'default-character-set'} = $character_set_server;

	return $dumpcommand;
}

sub mysqldump_connection_file() {
	my ($mycnf_client) = @_;

	my $mysqldumpoptions = "";

	# Defaults-Extra-File
	if ( defined($mycnf_client) ) {
		$mysqldumpoptions =
		  $mysqldumpoptions . "--defaults-file='" . $mycnf_client . "' ";
		return $mysqldumpoptions;
	}

	my $connfh;
	my $filename = "mydump.cnf";

	open( my $connfh, ">", $filename ) or die "cannot open > output.txt: $!";

	chmod( 0600, $filename );

	print $connfh "[client]\n";

	# Always used
	if ( defined( $opt->{user} ) ) {
		print $connfh "user = " . $opt->{user} . "\n";
	}
	if ( defined( $opt->{password} ) ) {
		print $connfh "password = " . $opt->{password} . "\n";
	}

	# Socket
	if ( defined( $opt->{socket} ) ) {
		print $connfh "socket = " . $opt->{socket} . "\n";
	}

	# TCP/IP
	if ( defined( $opt->{host} ) ) {
		print $connfh "host = " . $opt->{host} . "\n";
	}
	if ( defined( $opt->{port} ) ) {
		print $connfh "port = " . $opt->{port} . "\n";
	}

	# Optimize
	# print $connfh "line-numbers = 1\n";
	# print $connfh "reconnect = 1\n";
	# print $connfh "wait = 1\n";
	# init-command
	close $connfh;

	$mysqldumpoptions = "--defaults-file=\"" . $filename . "\" ";

	return $mysqldumpoptions;
}

sub mysqldump_connection_get() {
	my $mysqldumpoptions = "";

	my $connfh;
	open( my $connfh, ">", "mydump.cnf" ) or die "cannot open > output.txt: $!";

	# Defaults-Extra-File
	if ( defined( $opt->{mycnf_client} ) ) {
		$mysqldumpoptions =
		    $mysqldumpoptions
		  . "--defaults-extra-file='"
		  . $opt->{mycnf_client} . "' ";
		return $mysqldumpoptions;
	}

	# Always used
	if ( defined( $opt->{user} ) ) {
		$mysqldumpoptions =
		  $mysqldumpoptions . '--user="' . $opt->{user} . '" ';
	}
	if ( defined( $opt->{password} ) ) {
		$mysqldumpoptions =
		  $mysqldumpoptions . '--password="' . $opt->{password} . '" ';
	}

	# Socket
	if ( defined( $opt->{'socket'} ) ) {
		$mysqldumpoptions =
		  $mysqldumpoptions . '--socket="' . $opt->{socket} . '" ';
		return $mysqldumpoptions;
	}

	# TCP/IP
	if ( defined( $opt->{host} ) ) {
		$mysqldumpoptions =
		  $mysqldumpoptions . '--host="' . $opt->{host} . '" ';
	}
	if ( defined( $opt->{port} ) ) {
		$mysqldumpoptions = $mysqldumpoptions . '--port=' . $opt->{port} . ' ';
	}

	return $mysqldumpoptions;
}
1;

#------------------------------------------------------------------------------
# SYSTEM VARIABLES
#------------------------------------------------------------------------------
package sysenv;

sub systemvariables_global_get() {
	my %ret;

	my $sth = $dbh->prepare("SHOW GLOBAL VARIABLES");
	$sth->execute();

	while ( my $rs = $sth->fetchrow_hashref ) {
		$ret{ $rs->{'Variable_name'} } = $rs->{'Value'};
	}
	return \%ret;
}

sub systemvariables_global_dump_set() {
	my ($configfile) = @_;

	my $privconfig = new ConfigFile($configfile);

	my $variables = $privconfig->segment_get('sysvar_dump');

	foreach my $var ( keys %$variables ) {

		my $re = systemvariable_global_set( $var, $variables->{$var} );

		if ($re) {
			$systemvariables->{'new'}->{$var} = $variables->{$var};
		}
	}
}

sub systemvariables_global_reset($) {
	my ($sysvar_org) = @_;

	my $sysvar_act = systemvariables_global_get();

	foreach my $var ( keys %{$sysvar_org} ) {
		if ( $sysvar_org->{$var} ne $sysvar_act->{$var} ) {
			systemvariable_global_set( $var, $sysvar_org->{$var} );
		}
	}
}

sub systemvariable_global_set($$) {
	my ( $systemvariable, $value ) = @_;

	local $SIG{__WARN__} = sub { die $_[0] };

	my ( $ret, $sql );
	eval { $ret = int($value); };

	if ($@) {
		$value = "'$value'";
	}
	$sql = "SET GLOBAL $systemvariable=" . $value;

	$dbh->do($sql);

	return 1;
}

#------------------------------------------------------------------------------
# BINLOG SAVE
#------------------------------------------------------------------------------
package BinlogSave;
# TODO

sub new
{
    my $class = shift;
    my $self = {
        _firstposition => shift,
        _lastposition  => shift,
        _ssn       => shift,
    };
    bless $self, $class;
    return $self;
}

sub save(){
	
};

sub rotate() {
	my $ret;

	$dbh->{'mysql_serverinfo'} =~ /^([0-9]{1})\.([0-9]{1,2})\.([0-9]{1,3}).*$/;
	my $versionvalue = 10000 * $1 + 100 * $2 + $3;

	$ret = $dbh->do("FLUSH NO_WRITE_TO_BINLOG /*!50503 BINARY */ LOGS");

	my ( $binlog, $position );
	if ( $ret == 1 ) {
		( $binlog, $position ) = position_get();
	}
	return $binlog;
}

sub position_get() {
	my $sth = $dbh->prepare("SHOW MASTER STATUS");

	$sth->execute();

	my $rs = $sth->fetchrow_hashref();

	$rs =~ /.*\.[0-9]+$/;    # greedy is right

	return ( $1, $rs->{'Position'} );
}

1;

#------------------------------------------------------------------------------
# FILESYSTEM
#------------------------------------------------------------------------------
package Filesystem;

sub files_remove($$){
	my ($directory,$days) = @_;
	
	die unless chdir $directory;
	die unless opendir DIR, ".";
	# -f : REMOVE only plain files
	# /^.*\.sql(\.(gz|lzo)){0,1}$/ : REMOVE only *.sql, *.sql.gz or *.sql.lzo files
	# $days -M : REMOVE files older than $days   
	
	foreach my $file (grep {-f && /^.*\.sql(\.(gz|lzo)){0,1}$/ && ($days < -M)} readdir DIR) {
	    my $ret = unlink $file;
	    $log->info("rm '".$file."':".$ret);
	}
	
	closedir DIR;	
};


1;