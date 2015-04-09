#!/usr/bin/perl
#
# Copyright 2015 Comcast Cable Communications Management, LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

use strict;
use warnings;
use feature qw(switch);
use JSON;
use File::Basename;
use File::Path;
use Fcntl qw(:flock);
use Data::Dumper;

$| = 1;	
my $script_version = "0.47a";
my $date = `/bin/date`; chomp($date);
print "$date\nVersion of this script: $script_version\n";

if ($#ARGV < 1) {
	&usage();
}

my $log_level = 0;
$ARGV[1] = uc($ARGV[1]);
given($ARGV[1]) {
	when("ALL") 	{ $log_level = 	255; }
	when("TRACE") 	{ $log_level = 	127; }
	when("DEBUG") 	{ $log_level = 	 63; }
	when("INFO") 	{ $log_level = 	 31; }
	when("WARN") 	{ $log_level = 	 15; }
	when("ERROR") 	{ $log_level = 	  7; }
	when("FATAL") 	{ $log_level = 	  3; }
	when("NONE") 	{ $log_level = 	  1; }
	default 		{ &usage(); }
}

my $traffic_ops_host	= undef;
my $TM_LOGIN			= undef;

if (defined($ARGV[2])) {
	if ($ARGV[2] !~ /^https*:\/\/.*$/) {
		&usage();
	}
	else {
		$traffic_ops_host = $ARGV[2];
		$traffic_ops_host =~ s/\/*$//g;
	}	
}
else {
	&usage();
}

if (defined($ARGV[3])) {
	if ($ARGV[3] !~ m/^.*\:.*$/) {
		&usage();
	}
	else {
		$TM_LOGIN = $ARGV[3];
	}	
}
else {
	&usage();
}

#### Script mode constants ####
my $INTERACTIVE = 0;
my $REPORT 	= 1;
my $BADASS 	= 2;
my $SYNCDS 	= 3;
#### Logging constants for bit shifting #### 
my $ALL 	= 7;
my $TRACE 	= 6;
my $DEBUG 	= 5;
my $INFO 	= 4;
my $WARN 	= 3;
my $ERROR 	= 2;
my $FATAL 	= 1;
my $NONE 	= 0;

my $script_mode = &check_script_mode();
&check_run_user();
&check_only_copy_running();
&check_log_level();

#### Constants to track update status #### 
my $UPDATE_TROPS_NOTNEEDED 	= 0;
my $UPDATE_TROPS_NEEDED 		= 1;
my $UPDATE_TROPS_SUCCESSFUL 	= 2;
my $UPDATE_TROPS_FAILED 		= 3;
#### Other constants #####
my $START_FAILED 		= 0;
my $START_SUCCESSFUL 	= 1;
my $ALREADY_RUNNING 	= 2;
my $START_NOT_ATTEMPTED	= 3;
my $CLEAR 				= 0;
my $PLUGIN_NO			= 0;
my $PLUGIN_YES			= 1;
#### Constants for config file changes #### 
my $CFG_FILE_UNCHANGED		= 0;
my $CFG_FILE_NOT_PROCESSED	= 1;
my $CFG_FILE_CHANGED		= 2;
my $CFG_FILE_PREREQ_FAILED	= 3;

my $unixtime = time();
my $hostname_short = `/bin/hostname -s`; chomp($hostname_short);
my $domainname = &set_domainname();

my $TMP_BASE = "/tmp/ort";
my $cookie = &get_cookie($traffic_ops_host, $TM_LOGIN);
my $CURL_OPTS = "-w %{response_code} -k -L -s -S --connect-timeout 5 --retry 5 --retry-delay 5 --basic";
if ($cookie) {
	$CURL_OPTS = "-H 'Cookie:" . $cookie . "' " . $CURL_OPTS;
}
($log_level >> $DEBUG) && print "DEBUG CURL_OPTS: $CURL_OPTS.\n";
my $YUM_OPTS = "--disablerepo=*atlas*";
($log_level >> $DEBUG) && print "DEBUG YUM_OPTS: $YUM_OPTS.\n";
my $TS_HOME = "/opt/trafficserver";
my $TRAFFIC_LINE = $TS_HOME . "/bin/traffic_line";

my $out = `/usr/bin/yum $YUM_OPTS clean metadata 2>&1`;
my $return = &check_output($out);
my @config_files = ();

#### Process reboot tracker 
my $reboot_needed 			= 0;
my $traffic_line_needed 		= 0;
my $sysctl_p_needed 			= 0;
my $ntpd_restart_needed 		= 0;
my $trafficserver_restart_needed 	= 0;

#### Process runnning tracker
my $ats_running 			= 0;

#### Process installed tracker
my $installed_new_keys			= 0;
my $new_header_rewrite			= 0;
my %install_tracker;

my $config_dirs = undef;
my $cfg_file_tracker = undef;

####-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-####
#### Start main flow
####-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-####

#### First and foremost, if this is a syncds run, check to see if we can bail.
my $syncds_update = undef;
if (defined $traffic_ops_host) {
	($syncds_update) = &check_syncds_state();
}
else {
	print "FATAL Could not resolve Traffic Ops host!\n";
	exit 1;
}	

#### Delete /tmp dirs older than one week
if ($script_mode == $BADASS || $script_mode == $INTERACTIVE || $script_mode == $SYNCDS) {
	&smart_mkdir($TMP_BASE);
	&clean_tmp_dirs();
}

(my $my_profile_name, $cfg_file_tracker, my $my_cdn_name) = &get_cfg_file_list($hostname_short, $traffic_ops_host);
my $header_comment = &get_header_comment($traffic_ops_host);

&process_packages($hostname_short, $traffic_ops_host);
&process_chkconfig($hostname_short, $traffic_ops_host);
&process_config_files();

#### Check to see if we installed new keys.
if (($installed_new_keys || $new_header_rewrite) && !$cfg_file_tracker->{'remap.config'}->{'change_applied'}) {
	my $return = &touch_file('remap.config');
	if ($return) {
    	if ($syncds_update == $UPDATE_TROPS_NEEDED) {
        	$syncds_update = $UPDATE_TROPS_SUCCESSFUL;
    	}
		$traffic_line_needed++;
	}
}

&start_restart_services();

if ($sysctl_p_needed && $script_mode != $SYNCDS) {
	&run_sysctl_p();
}

&check_ntp();

if ($script_mode != $REPORT) {
	&update_trops(); 
}

####-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-####
#### End main flow
####-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-####


####-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-####
#### Subroutines
####-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-####
sub usage {
	print "====-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-====\n";
	print "Usage: ./traffic_ops_ort.pl <Mode> <Log_Level> <Traffic_Ops_URL> <Traffic_Ops_Login>\n";
	print "\t<Mode> = interactive - asks questions during config process.\n";
	print "\t<Mode> = report - prints config differences and exits.\n";
	print "\t<Mode> = badass - attempts to fix all config differences that it can.\n";
	print "\t<Mode> = syncds - syncs delivery services with what is configured in Traffic Ops.\n";
	print "\n";
	print "\t<Log_Level> => ALL, TRACE, DEBUG, INFO, WARN, ERROR, FATAL, NONE\n";
	print "\n";
	print "\t<Traffic_Ops_URL> = URL to 12 monkeys host. Example: https://trafficops.company.net\n";
	print "\n";
	print "\t<Traffic_Ops_Login> => Example: 'username:password' \n";
	print "====-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-====\n";
	exit 1;
}

sub process_cfg_file {
	my $cfg_file = shift;
	my $service = shift;
	my $return_code = 0;
	my $url;
	my $result;
	if ($cfg_file eq "") {
		$cfg_file_tracker->{$cfg_file}->{'audit_failed'}++;
		return $CFG_FILE_NOT_PROCESSED;
	}
	my $config_dir = $cfg_file_tracker->{$cfg_file}->{'location'};
	($log_level >> $INFO) && print "\nINFO: ======== Start processing config file: $cfg_file ========\n";
	$cfg_file_tracker->{$cfg_file}->{'audit_start'}++;
	$cfg_file_tracker->{$cfg_file}->{'service'} = $service;
	$url = ($cfg_file ne "regex_revalidate.config") ? "$traffic_ops_host\/genfiles\/view\/$hostname_short\/$cfg_file" : "$traffic_ops_host\/Trafficserver-Snapshots\/$my_cdn_name\/$cfg_file";
	if (!-d($config_dir)) {
		if ($script_mode == $BADASS || $script_mode == $INTERACTIVE || $script_mode == $SYNCDS) {
			&smart_mkdir($config_dir);
		}
		else {
			($log_level >> $ERROR) && print "ERROR Directory: $config_dir not created. Skipping processing on $cfg_file.\n";
			return $CFG_FILE_NOT_PROCESSED;
		}
	}
	if (!defined($result)) {
		$result = &curl_me($url);
	}
	if ($result =~ m/^\d{3}$/) {
		return $CFG_FILE_NOT_PROCESSED;
	}
	my $size = length($result);
	if ($size == 131) {
		($log_level >> $WARN) && print "WARN URL: $url returned only the header.\n";
	}
	elsif ($size == 0) {
		($log_level >> $ERROR) && print "ERROR URL: $url returned empty!! Skipping future processing on $cfg_file.\n";
		return $CFG_FILE_NOT_PROCESSED;
	}
	else {
		($log_level >> $DEBUG) && print "DEBUG URL: $url returned $size bytes.\n";
	}
	(my @file_lines) = split(/\n/, $result);
	my %db_file_lines;
	foreach my $line (@file_lines) {
		$line =~ s/\s+/ /g;
		$line =~ s/(^\s+|\s+$)//g;
		$line =~ s/amp\;//g;
		$line =~ s/\&gt\;/\>/g;
		$line =~ s/\&lt\;/\</g;
		chomp($line); 
		if ( $line =~ m/^$/ ) { next; }
		($log_level >> $TRACE) && print "TRACE Line from cfg file in TrOps:\t$line.\n";
		$db_file_lines{$line} = defined;
	}
	($log_level >> $DEBUG) && print "DEBUG Opening file from disk:\t$config_dir/$cfg_file.\n";
	open my $fh, '<', "$config_dir/$cfg_file" || (($log_level >> $ERROR) && print "ERROR Can't open $config_dir/$cfg_file\n");
	my %disk_file_lines;
	if ($! =~ m/No such file or directory/) {
		($log_level >> $ERROR) && print "ERROR $! on opening $config_dir/$cfg_file.\n";
		$cfg_file_tracker->{$cfg_file}->{'no_such_file'}++;
	}
	if ($! =~ m/Permission denied/) {
		($log_level >> $ERROR) && print "ERROR $! on opening $config_dir/$cfg_file.\n";
		$cfg_file_tracker->{$cfg_file}->{'permission_denied'}++;
	}
	elsif ($! =~ m/Inappropriate ioctl for device/ || $! =~ m/No such file or directory/) {
		if ($! =~ m/Inappropriate ioctl for device/) {
			while (<$fh>) {
				my $line = $_;
				$line =~ s/\s+/ /g;
				$line =~ s/(^\s+|\s+$)//g;
				chomp($line); 
				($log_level >> $TRACE) && print "TRACE Line from cfg file on disk:\t$line.\n";
				if ($line =~ m/^\#/ || $line =~ m/^$/ ) { 
					if ( ($line !~ m/DO NOT EDIT - Generated for / && $line !~ m/$header_comment/) && $line !~ m/12M NOTE\:/) {
						next; 
					}
				}
				$disk_file_lines{$line} = defined; 
			}
			close $fh;
		}
		if ($cfg_file eq "plugin.config" || $cfg_file eq "remap.config") {
			&check_plugins($cfg_file, \%db_file_lines);
			if ($cfg_file_tracker->{$cfg_file}->{'prereq_failed'}) {
				($log_level >> $ERROR) && print "ERROR Prereqs failed for $cfg_file!\n";
				$return_code = $CFG_FILE_PREREQ_FAILED;
			}
		}
		my %disk_lines_missing = ();
		my %db_lines_missing = ();
		foreach my $line ( sort keys %db_file_lines ) {
			if (!exists $disk_file_lines{$line}) {
				#### Float compare
				if ($line =~ m/FLOAT/) {
					(my $disk_dum, my $disk_name, my $disk_type, my $disk_val) = split(/\s/, $line);
					foreach my $l ( sort keys %db_file_lines ) {
						(my $db_dum, my $db_name, my $db_type, my $db_val) = split(/\s/, $l);
						if ($db_name eq $disk_name && $db_type eq $disk_type) {
							if ( abs($disk_val - $db_val) > 0.00001 ) {
								$disk_lines_missing{$line} = defined;
							}
						}
					}
				}
                elsif ( ($line =~ m/DO NOT EDIT - Generated for / && $line =~ m/$header_comment/) || $line =~ m/12M NOTE\:/) {
					my $found_it = 0;
					foreach my $line_disk ( sort keys %disk_file_lines ) {
	                    if ( ($line =~ m/DO NOT EDIT - Generated for / && $line =~ m/$header_comment/) || $line =~ m/12M NOTE\:/) {
							$found_it++;
						}
					}
					if (!$found_it) {
						$disk_lines_missing{$line} = defined;
					}
				}
				else {
					$disk_lines_missing{$line} = defined;
				}
			}
		}
		foreach my $line ( sort keys %disk_file_lines ) {
			if (!exists $db_file_lines{$line}) {
				#### Float compare
				if ($line =~ m/FLOAT/) {
					(my $db_dum, my $db_name, my $db_type, my $db_val) = split(/\s/, $line);
					foreach my $l ( sort keys %disk_file_lines ) {
						(my $disk_dum, my $disk_name, my $disk_type, my $disk_val) = split(/\s/, $l);
						if ($db_name eq $disk_name && $db_type eq $disk_type) {
							if ( abs($disk_val - $db_val) > 0.00001 ) {
								$db_lines_missing{$line} = defined;
							}
						}
					}
				}
                elsif ( ($line =~ m/DO NOT EDIT - Generated for / && $line =~ m/$header_comment/) || $line =~ m/12M NOTE\:/) {
					next;
				}
				else {
					$db_lines_missing{$line} = defined;
				}
			}
		}
		if ( keys %db_lines_missing ) {
			my $line_count = scalar(keys %db_lines_missing);
			($log_level >> $DEBUG) && print "DEBUG $line_count lines in $cfg_file are missing from file that is in Traffic Ops.\n";
			$cfg_file_tracker->{$cfg_file}->{'db_lines_missing_count'} = $line_count;
		}
		elsif ( keys %disk_lines_missing ) {
			my $line_count = scalar(keys %disk_lines_missing);
			($log_level >> $DEBUG) && print "DEBUG $line_count lines in $cfg_file are missing from file that is on disk.\n";
			$cfg_file_tracker->{$cfg_file}->{'disk_lines_missing_count'} = $line_count;
		}
		if ( keys %disk_lines_missing || keys %db_lines_missing ) {
			$cfg_file_tracker->{$cfg_file}->{'change_needed'}++;
			($log_level >> $ERROR) && print "ERROR Lines in $config_dir/$cfg_file do not match Traffic Ops.\n";
			foreach my $line ( sort keys %disk_lines_missing ) {
				($log_level >> $ERROR) && print "ERROR Config file: $cfg_file line only in TrOps:\t$line\n";
			}
			foreach my $line ( sort keys %db_lines_missing ) {
				($log_level >> $ERROR) && print "ERROR Config file: $cfg_file line only on disk:\t$line\n";
			}
			if ($script_mode != $REPORT) {
				my $bkp_dir;
				my $bkp_file;
				if (-e "$config_dir/$cfg_file") {
					($log_level >> $ERROR) && print "ERROR Creating backup of file on disk for $cfg_file.\n";
					$bkp_dir = $TMP_BASE . "/" . $unixtime . "/" . $cfg_file_tracker->{$cfg_file}->{'service'} . "/config_bkp/";
					$bkp_file = $bkp_dir . $cfg_file;
					&smart_mkdir($bkp_dir);
					($log_level >> $DEBUG) && print "DEBUG Backup file: $bkp_file.\n";
					$cfg_file_tracker->{$cfg_file}->{'backup_from_disk'} = $bkp_file;
					system("/bin/cp $config_dir/$cfg_file $bkp_file");
				}
				else {
					($log_level >> $DEBUG) && print "DEBUG Config file: $config_dir/$cfg_file doesn't exist. No need to back up.\n";
				}
				($log_level >> $ERROR) && print "ERROR Creating backup of file in TrOps for $cfg_file.\n";
				$bkp_dir = $TMP_BASE . "/" . $unixtime . "/" . $cfg_file_tracker->{$cfg_file}->{'service'} . "/config_trops/";
				$bkp_file = $bkp_dir . $cfg_file;
				&smart_mkdir($bkp_dir);
				($log_level >> $DEBUG) && print "DEBUG Backup file: $bkp_file.\n";
				$cfg_file_tracker->{$cfg_file}->{'backup_from_trops'} = $bkp_file;
				open my $fh, '>', $bkp_file || die "Can't open $bkp_file for writing!\n";
				print $fh $result;
				chmod oct(644), $fh;
				chown 176, 176, $fh;
				close $fh;
			}
		}
		else {
			($log_level >> $INFO) && print "INFO: All lines match TrOps for config file: $cfg_file.\n";
			$cfg_file_tracker->{$cfg_file}->{'change_needed'}=0;
			($log_level >> $TRACE) && print "TRACE Setting change not needed for $cfg_file.\n";
			$return_code = $CFG_FILE_UNCHANGED;
		}
		if ($cfg_file eq "50-ats.rules") {
			($log_level >> $TRACE) && print "TRACE Entering advanced processing for 50-ats.rules.\n";
			foreach my $line50 (@file_lines) {
				if ($line50 =~ m/KERNEL/ && $line50 =~ m/OWNER/) {
					(my $dev, my $should_own) = split (/,/, $line50);
					$dev =~ s/KERNEL\s*\=\=\s*//g; 		$dev =~ s/\"//g;
					$should_own =~ s/ OWNER\s*:?\=\s*//g;	$should_own =~ s/\"//g;

					my $dev_path = "/dev/$dev";
					my $dc = undef;

					next if ($should_own eq "root");

					my $ats_uid = `/usr/bin/id $should_own 2>&1`;

					if ($ats_uid =~ m/No such user/) { 
						($log_level >> $ERROR) && print "ERROR User: $should_own does not exist! Skipping future checks for $dev_path\n";
						next;
					}

					chomp($ats_uid);	$ats_uid =~ s/\((.*)$//g;	$ats_uid =~ s/uid\=//g;

					if (-e $dev_path) {
						($log_level >> $TRACE) && print "TRACE Found device in 50-ats.rules: $dev_path.\n";
						($dc,$dc,$dc,$dc,my $uid,$dc,$dc,$dc,$dc,$dc,$dc,$dc,$dc) = stat($dev_path);
						if ($uid != $ats_uid) {
							($log_level >> $ERROR) && print "ERROR Device $dev_path is owned by $uid, not $should_own ($ats_uid)\n";
						}
						(my @df_lines) = split(/\n/, `/bin/df`);
						foreach my $l (@df_lines) {
							if ($l =~ m/$dev_path/) {
								($log_level >> $FATAL) && print "FATAL Device /dev/$dev has an active partition and a file system!!\n";
							}
						}
					} 
					else {
						open(DEV, "ls /dev/* |") or ($log_level >> $FATAL) && print "FATAL Couldn't get /dev/ listing: $!\n";
						while (my $dnode = <DEV>) {
							next unless ($dnode =~ m!$dev_path!);

							chomp $dnode;
							next if ($dnode =~ m!/dev/sda[0-9]*!);

							($log_level >> $TRACE) && print "TRACE Found device in 50-ats.rules: $dnode.\n";
							($dc,$dc,$dc,$dc,my $uid,$dc,$dc,$dc,$dc,$dc,$dc,$dc,$dc) = stat($dnode);
							if ($uid != $ats_uid) {
								($log_level >> $ERROR) && print "ERROR Device $dnode is owned by $uid, not $should_own ($ats_uid)\n";
							}
							(my @df_lines) = split(/\n/, `/bin/df`);
							foreach my $l (@df_lines) {
								if ($l =~ m/$dnode/) {
									($log_level >> $FATAL) && print "FATAL Device /dev/$dev has an active partition and a file system!!\n";
								}
							}
						}
						close(DEV);
					}
				}
			} 
		}
	}
	else {
		($log_level >> $ERROR) && print "ERROR Unhandled error $! when opening $config_dir/$cfg_file.\n";
	}
	($log_level >> $INFO) && print "INFO: ======== End processing config file: $cfg_file for service: $service ========\n";
	$cfg_file_tracker->{$cfg_file}->{'audit_complete'}++;
	return $return_code;
}

sub start_service {
	my $pkg_name = shift; 
	(my $pkg_running) = `/sbin/service $pkg_name status`;
	my $running_string = "";
	if ($pkg_name eq "trafficserver") {
		$running_string = "traffic_cop";
	}
	else {
		$running_string = $pkg_name;
	}
	if ($running_string ne "") {
		if ($pkg_running !~ m/$running_string \(pid\s+(\d+)\) is running.../) {
			if ($script_mode == $REPORT || $script_mode == $SYNCDS) {
				($log_level >> $ERROR) && print "ERROR $pkg_name is not running.\n";	
				$pkg_running = $START_NOT_ATTEMPTED;
			}
			elsif ($script_mode == $BADASS) {
				($log_level >> $ERROR) && print "ERROR $pkg_name needs started. Trying to do that now.\n";	
				my $pkg_start_output = `/sbin/service $pkg_name start`;
				(my @output_lines) = split(/\n/, $pkg_start_output);
				my $pkg_started = 0;
				foreach my $ol (@output_lines) {
					if ($ol =~ m/\[.*\]/ && $ol =~ m/OK/) {
						$pkg_started++;
					}
				}
				if ($pkg_started) {
					($log_level >> $ERROR) && print "ERROR $pkg_name started successfully.\n";	
					$pkg_running = $START_SUCCESSFUL;
				}
				else {
					$pkg_start_output =~ s/\n/\t/g;
					$pkg_start_output =~ s/\r/\t/g;
					($log_level >> $ERROR) && print "ERROR $pkg_name failed to start, error is: $pkg_start_output.\n";	
					$pkg_running = $START_FAILED;
				}
			}
			elsif ($script_mode == $INTERACTIVE) {
				my $select = 'Y';
				($log_level >> $ERROR) && print "ERROR $pkg_name is not running. Should I start it now? (Y/n) [n]";
				$select = <STDIN>;
				chomp($select);
				if ($select =~ m/Y/) {
					($log_level >> $ERROR) && print "ERROR $pkg_name needs started. Trying to do that now.\n";	
					my $pkg_start_output = `/sbin/service $pkg_name start`;
					(my @output_lines) = split(/\n/, $pkg_start_output);
					my $pkg_started = 0;
					foreach my $ol (@output_lines) {
						if ($ol =~ m/\[.*\]/ && $ol =~ m/OK/) {
							$pkg_started++;
						}
					}
					if ($pkg_started) {
						($log_level >> $DEBUG) && print "DEBUG $pkg_name started successfully.\n";	
						$pkg_running = $START_SUCCESSFUL;
					}
					else {
						$pkg_start_output =~ s/\n/\t/g;
						($log_level >> $ERROR) && print "ERROR $pkg_name failed to start, error is: $pkg_start_output.\n";	
						$pkg_running = $START_FAILED;
					}
				}
			}
		}
		else {
			($log_level >> $DEBUG) && print "DEBUG $pkg_name is running.\n";	
			$pkg_running = $ALREADY_RUNNING;
		}
	}
	else {
		($log_level >> $FATAL) && print "FATAL Unrecognized service: $pkg_name. Not starting $pkg_name.\n";	
	}
	return $pkg_running;
}

sub restart_service {
	my $pkg_name = $_[0];
	(my $pkg_running) = `/sbin/service $pkg_name status`;
	my $running_string = "";
	if ($pkg_name eq "trafficserver") {
		$running_string = "traffic_cop";
	}
	if ($running_string ne "") {
		if ($pkg_running =~ m/$running_string \(pid  (\d+)\) is running.../) {
			if ($script_mode == $REPORT) {
				($log_level >> $ERROR) && print "ERROR $pkg_name needs to be restarted. Please run 'service $pkg_name restart' to fix.\n";	
			}
			if ($script_mode == $BADASS) {
				($log_level >> $ERROR) && print "ERROR Trying to restart $pkg_name.\n";	
				my $pkg_start_output = `/sbin/service $pkg_name restart`;
				(my @output_lines) = split(/\n/, $pkg_start_output);
				my $pkg_started = 0;
				foreach my $ol (@output_lines) {
					if ($ol =~ m/\[.*\]/ && $ol =~ m/OK/) {
						$pkg_started++;
					}
				}
				if ($pkg_started) {
					($log_level >> $ERROR) && print "ERROR $pkg_name restarted successfully.\n";	
					$pkg_running++;
				}
				else {
					$pkg_start_output =~ s/\n/\t/g;
					($log_level >> $ERROR) && print "ERROR $pkg_name failed to restart, error is: $pkg_start_output.\n";	
				}
			}
			if ($script_mode == $INTERACTIVE) {
				my $select = 'Y';
				($log_level >> $ERROR) && print "ERROR $pkg_name needs to be restarted. Should I restart it now? (Y/n) [n]";
				$select = <STDIN>;
				chomp($select);
				if ($select =~ m/Y/) {
					($log_level >> $DEBUG) && print "DEBUG Trying to restart $pkg_name.\n";	
					my $pkg_start_output = `/sbin/service $pkg_name restart`;
					(my @output_lines) = split(/\n/, $pkg_start_output);
					my $pkg_started = 0;
					foreach my $ol (@output_lines) {
						if ($ol =~ m/\[.*\]/ && $ol =~ m/OK/) {
							$pkg_started++;
						}
					}
					if ($pkg_started) {
						($log_level >> $DEBUG) && print "DEBUG $pkg_name restarted successfully.\n";	
						$pkg_running++;
					}
					else {
						$pkg_start_output =~ s/\n/\t/g;
						($log_level >> $ERROR) && print "ERROR $pkg_name failed to restart, error is: $pkg_start_output.\n";	
					}
				}
			}
		}
		else {
			($log_level >> $DEBUG) && print "DEBUG $pkg_name is not running! This shouldn't happnen, $pkg_name must have died recently!\n";	
			$pkg_running++;
		}
	}
	else {
		($log_level >> $FATAL) && print "FATAL Unrecognized service: $pkg_name. Not restarting $pkg_name.\n";	
	}
	return $pkg_running;
}

sub smart_mkdir {
	my $dir = $_[0];
	($log_level >> $TRACE) && print "TRACE Directory to create if needed: $dir\n";
	if (!-d $dir) {
		system("/bin/mkdir -p $dir");
		if ($dir =~ m/config_trops/) {
			($log_level >> $DEBUG) && print "DEBUG Temp directory created: $dir. Config files from Traffic Ops will be placed here for future processing.\n";
		}
		elsif ($dir =~ m/config_bkp/) {
			($log_level >> $DEBUG) && print "DEBUG Backup directory created: $dir. Config files will be backed up here.\n";
		}
		else {
			($log_level >> $DEBUG) && print "DEBUG Directory created: $dir.\n";
		}
	}
}

sub clean_tmp_dirs {
	my $old_time = $unixtime - 604800;
	($log_level >> $ERROR) && print "ERROR Deleting directories older than $old_time\n";
    opendir(DIR, $TMP_BASE) || err("Could not open $TMP_BASE: $!\n");
    my @dirs = grep(/\d{10}/, readdir(DIR));
    closedir(DIR);
	foreach my $dir (@dirs) {
		if ($dir <= $old_time) {
			($log_level >> $ERROR) && print "ERROR Deleting directory $TMP_BASE/$dir\n";
			system("rm -rf $TMP_BASE/$dir");
		}
	}
}

sub update_trops {
	my $update_result = 0;
	if ($syncds_update == $UPDATE_TROPS_NOTNEEDED) {
		($log_level >> $DEBUG) && print "DEBUG Traffic Ops does not require an update at this time.\n";
		return 0;
	}
	elsif ($syncds_update == $UPDATE_TROPS_FAILED) {
		($log_level >> $ERROR) && print "ERROR Traffic Ops requires an update, but applying the update locally failed. Traffic Ops is not being updated!\n";
		return 1;
	}
	elsif ($syncds_update == $UPDATE_TROPS_SUCCESSFUL) {
		($log_level >> $ERROR) && print "ERROR Traffic Ops required an update, and it was applied successfully. Clearing update state in Traffic Ops.\n";
		$update_result++;
	}
	elsif ($syncds_update == $UPDATE_TROPS_NEEDED) {
		($log_level >> $ERROR) && print "ERROR Traffic Ops is signaling that an update is ready to be applied, but none was found! Clearing update state in Traffic Ops anyway.\n";
		$update_result++;
	}
	if ($update_result) {	
		if ($script_mode == $INTERACTIVE) {
			($log_level >> $ERROR) && print "ERROR Traffic Ops needs updated. Should I do that now? [Y/n] (n): ";
			my $select = 'n';
       			$select = <STDIN>;
    	   		chomp($select);
   	    		if ($select =~ m/Y/) {
				&send_update_to_trops($CLEAR);
			}
			else {
				($log_level >> $ERROR) && print "ERROR Traffic Ops needs updated. You elected not to do that now; you should probably do that manually.\n";
			}
		}
		elsif ($script_mode == $BADASS || $script_mode == $SYNCDS) {
			&send_update_to_trops($CLEAR);
		}
	}
}

sub send_update_to_trops {
	my $status = shift;
	my $url = "$traffic_ops_host\/update/$hostname_short";
	($log_level >> $DEBUG) && print "DEBUG Setting update flag in Traffic Ops to $status.\n";
	my $cmd = undef;
	if ($cookie) {
		$cmd = "/usr/bin/curl -k -L -s -H 'Cookie: $cookie' -X POST -d 'updated=$status' --basic $url 2>&1"
	}
	else {
		$cmd = "/usr/bin/curl -k -L -s -X POST -d 'updated=$status' --basic $url 2>&1"
	}
	my $result = `$cmd`;
	($log_level >> $DEBUG) && print "DEBUG Response from Traffic Ops is: $result.\n";
}

sub get_print_current_client_connections {
	my $cmd = $TRAFFIC_LINE . " -r proxy.process.http.current_client_connections";	
	my $current_connections = `$cmd 2>/dev/null`;
	chomp($current_connections);
	($log_level >> $DEBUG) && print "DEBUG There are currently $current_connections connections.\n";
}

sub check_syncds_state {
		
	my $syncds_update = 0;

	($log_level >> $DEBUG) && print "DEBUG Checking syncds state.\n";
	if ($script_mode == $SYNCDS || $script_mode == $BADASS || $script_mode == $REPORT) {
		## The herd is about to get /update/<hostname>
		&sleep_rand(5);

		my $url = "$traffic_ops_host\/update/$hostname_short";
		my $upd_ref = &curl_me($url);
		if ($upd_ref =~ m/^\d{3}$/) {
			($log_level >> $ERROR) && print "ERROR Update URL: $url returned $upd_ref. Exiting, not sure what else to do.\n";
			exit 1;
		}

		my $upd_json = decode_json($upd_ref);
		my $upd_pending = (defined($upd_json->[0]->{'upd_pending'})) ? $upd_json->[0]->{'upd_pending'} : undef;
		if (!defined($upd_pending)) {
			($log_level >> $ERROR) && print "ERROR Update URL: $url did not have an upd_pending key.\n";
			if ($script_mode != $SYNCDS) {
				return $syncds_update;
			}
			else {
				($log_level >> $ERROR) && print "ERROR Invalid JSON for $url. Exiting, not sure what else to do.\n";
				exit 1;
			}
		}

		if ( $upd_pending == 1 ) {
			($log_level >> $ERROR) && print "ERROR Traffic Ops is signaling that an update is waiting to be applied.\n";
			$syncds_update = $UPDATE_TROPS_NEEDED;
			
			my $parent_pending = (defined($upd_json->[0]->{'parent_pending'})) ? $upd_json->[0]->{'parent_pending'} : undef;
			if (!defined($parent_pending)) {
				($log_level >> $ERROR) && print "ERROR Update URL: $url did not have an parent_pending key.\n";
				if ($script_mode != $SYNCDS) {
					return $syncds_update;
				}
				else {
					($log_level >> $ERROR) && print "ERROR Invalid JSON for $url. Exiting, not sure what else to do.\n";
					exit 1;
				}
			}
			if ($parent_pending == 1) {
				($log_level >> $ERROR) && print "ERROR Traffic Ops is signaling that my parents need an update.\n";
				if ($script_mode == $SYNCDS) {
					($log_level >> $WARN) && print "WARN In syncds mode, sleeping for 60s to see if the update my parents need is cleared.\n";
					for (my $i=60; $i>0; $i--) {
						($log_level >> $WARN) && print ".";
						sleep 1;
					}
					($log_level >> $WARN) && print "\n";
					$upd_ref = &curl_me($url);
					if ($upd_ref =~ m/^\d{3}$/) {
						($log_level >> $ERROR) && print "ERROR Update URL: $url returned $upd_ref. Exiting, not sure what else to do.\n";
						exit 1;
					}
					$upd_json = decode_json($upd_ref);
					$parent_pending = (defined($upd_json->[0]->{'parent_pending'})) ? $upd_json->[0]->{'parent_pending'} : undef;
					if (!defined($parent_pending)) {
						($log_level >> $ERROR) && print "ERROR Invalid JSON for $url. Exiting, not sure what else to do.\n";
					}
					if ($parent_pending == 1) {
						($log_level >> $ERROR) && print "ERROR My parents still need an update, bailing.\n";
						exit 1;

					}
					else {
						($log_level >> $DEBUG) && print "DEBUG The update on my parents cleared; continuing.\n";
						## At least a portion of the herd is about to check in with Traffic Ops, so need to space things out a bit.
						&sleep_rand(5);
					}
				}
			}
			else {
				($log_level >> $DEBUG) && print "DEBUG Traffic Ops is signaling that my parents do not need an update.\n";
				if ($script_mode == $SYNCDS) {
					## The herd is about to check in with Traffic Ops, need to space things out a bit.
					&sleep_rand(15);
				}
			}
		}
		elsif ($script_mode == $SYNCDS && $upd_pending != 1) {
			($log_level >> $ERROR) && print "ERROR In syncds mode, but no syncds update needs to be applied. I'm outta here.\n";
			exit 0;
		}
		else {
			($log_level >> $DEBUG) && print "DEBUG Traffic Ops is signaling that no update is waiting to be applied.\n";
		}

		my $stj = &curl_me("$traffic_ops_host\/datastatus");
		if ($stj =~ m/^\d{3}$/) {
			($log_level >> $ERROR) && print "Statuses URL: $url returned $stj! Skipping creation of status file.\n";
		}

		my $statuses = decode_json($stj);
		my $my_status = (defined($upd_json->[0]->{'status'})) ? $upd_json->[0]->{'status'} : undef;

		if (defined($my_status)) {
			($log_level >> $DEBUG) && print "DEBUG Found $my_status status from Traffic Ops.\n";
		}
		else {
			($log_level >> $ERROR) && print "ERROR Returning; did not find status from Traffic Ops!\n";
			return ($syncds_update);
		}

		my $status_dir = dirname($0) . "/status";
		my $status_file = $status_dir . "/" . $my_status;

		if (! -f $status_file) {
			($log_level >> $ERROR) && print "ERROR status file $status_file does not exist.\n";
		}

		for my $status (@{$statuses}) {
			next if ($status->{name} eq $my_status);
			my $other_status = $status_dir . "/" . $status->{name};

			if (-f $other_status && $status->{name} ne $my_status) {
				($log_level >> $ERROR) && print "ERROR Other status file $other_status exists.\n";
				if ($script_mode != $REPORT) {	
					($log_level >> $DEBUG) && print "DEBUG Removing $other_status\n";
					unlink($other_status);
				}
			}
		}
	
		if ($script_mode != $REPORT) {
			if (! -d $status_dir) {
				mkpath($status_dir);
			}

			if (! -f $status_file) {
				my $r = open(FH, "> $status_file");

				if (!$r) {
					($log_level >> $ERROR) && print "ERROR Unable to touch $status_file\n";
				} else {
					close(FH);
				}
			}
		}
	}
	return ($syncds_update);
}

sub sleep_rand {
	my $duration = shift;

	($log_level >> $WARN) && print "WARN Sleeping for $duration seconds: ";

	for (my $i=$duration; $i>0; $i--) {
		($log_level >> $WARN) && print ".";
		sleep 1;
	}
	($log_level >> $WARN) && print "\n";
}

sub process_config_files {

	($log_level >> $INFO) && print "\nINFO: ======== Start processing config files ========\n";
	foreach my $file ( sort keys %{$cfg_file_tracker}) {
		my $return = undef;
		if ($script_mode == $SYNCDS && 
		($file eq "records.config" || $file eq "remap.config" || $file eq "parent.config" || $file eq "cache.config" || $file eq "hosting.config" || 
		$file =~ m/url\_sig\_(.*)\.config$/ || $file =~ m/hdr\_rw\_(.*)\.config$/ || $file eq "regex_revalidate.config" || $file eq "ip_allow.config" ) ) {
			if (package_installed("trafficserver")) {
				($log_level >> $DEBUG) && print "DEBUG In syncds mode, I'm about to process config file: $file\n";
				$return = &process_cfg_file($file, "trafficserver");
			}
			else {
				($log_level >> $FATAL) && print "FATAL In syncds mode, but trafficserver isn't installed. Bailing.\n";
				exit 1;
			}
		}
		elsif ($script_mode == $SYNCDS && $file =~ m/\_facts/) {
			($log_level >> $DEBUG) && print "DEBUG In syncds mode, I'm about to process config file: $file\n";
			$return = &process_cfg_file($file, "puppet");
		}  
		elsif ($cfg_file_tracker->{$file}->{'location'} =~ m/cron/) {
			($log_level >> $DEBUG) && print "DEBUG In syncds mode, I'm about to process config file: $file\n";
			$return = &process_cfg_file($file, "system");
		}
		elsif ($script_mode != $SYNCDS) {
			if (package_installed("trafficserver") && ($cfg_file_tracker->{$file}->{'location'} =~ m/trafficserver/ || $cfg_file_tracker->{$file}->{'location'} =~ m/udev/ )) {
				$return = &process_cfg_file($file, "trafficserver");
			}
			elsif ($file eq "50-ats.rules") {
				$return = &process_cfg_file($file, "system");
			}
			elsif ($file eq "sysctl.conf") {
				$return = &process_cfg_file($file, "system");
			}
			elsif ($file eq "ntp.conf") {
				$return = &process_cfg_file($file, "ntpd");
			}
			elsif ($cfg_file_tracker->{$file}->{'location'} =~ m/\/opt\/ort/) {
				$return = &process_cfg_file($file, "puppet");
			}
			else {
				($log_level >> $WARN) && print "WARN $file is being processed with an unknown service\n";
				$return = &process_cfg_file($file, "unknown");
			}
		}
		if (defined($return) && $return == $CFG_FILE_PREREQ_FAILED) {
			$syncds_update = $UPDATE_TROPS_FAILED;
		} 
	}

	foreach my $file (sort keys %{$cfg_file_tracker} ) {
		if ( $cfg_file_tracker->{$file}->{'change_needed'} && $cfg_file_tracker->{$file}->{'audit_complete'} && !$cfg_file_tracker->{$file}->{'prereq_failed'} && !$cfg_file_tracker->{$file}->{'audit_failed'} ) {
			if  ( $file eq "plugin.config" && $cfg_file_tracker->{'remap.config'}->{'prereq_failed'} ) {
				($log_level >> $ERROR) && print "ERROR plugin.config changed. However, prereqs failed for remap.config so I am skipping updates for plugin.config.\n";
				next;
			}	
			elsif  ( $file eq "remap.config" && $cfg_file_tracker->{'plugin.config'}->{'prereq_failed'} ) {
				($log_level >> $ERROR) && print "ERROR remap.config changed. However, prereqs failed for plugin.config so I am skipping updates for remap.config.\n";
				next;
			}
			else {	
				($log_level >> $DEBUG) && print "DEBUG Prereqs passed for replacing $file on disk with that in Traffic Ops.\n";
				&replace_cfg_file($file);
			}
		}
	}
	($log_level >> $INFO) && print "\nINFO: ======== End processing config files ========\n\n";
}

sub touch_file {
	my $return = 0;
	my $file = shift;
	if (defined($cfg_file_tracker->{$file}->{'location'}) ) {
		$file = $cfg_file_tracker->{$file}->{'location'} . "/" . $file;
    	($log_level >> $DEBUG) && print "DEBUG About to touch $file.\n";
	}
	else {
		($log_level >> $ERROR) && print "ERROR $file has not location defined. Not touching $file.\n";
		return $return;
	}
	if ($script_mode == $INTERACTIVE) {
		($log_level >> $ERROR) && print "ERROR $file needs touched. Should I do that now? [Y/n] (n): ";
		my $select = 'n';
		$select = <STDIN>;
		chomp($select);
		if ($select =~ m/Y/) {
			$return = &touch_this_file($file);
		}
		else {
			($log_level >> $ERROR) && print "ERROR $file was not touched.\n";
		}
	}
	elsif ($script_mode == $BADASS || $script_mode == $SYNCDS) {
		($log_level >> $ERROR) && print "ERROR $file needs touched. Doing that now.\n";
		$return = &touch_this_file($file);
	}
	return $return;	
}

sub touch_this_file {
	my $file = shift;
	my $result = `/bin/touch $file 2>&1`;
	my $success = 0;
	chomp ($result);
	if ($result =~ m/cannot touch/ || $result =~ m/Permission denied/ || $result =~ m/No such file or directory/) {
		($log_level >> $ERROR) && print "ERROR $file was not touched successfully. Error: $result.\n";
		$success = 0;
	}
	else {
		($log_level >> $DEBUG) && print "DEBUG $file was touched successfully.\n";
		$success++;
	}
	return $success;
}

sub run_traffic_line {
	my $output = `$TRAFFIC_LINE -x 2>&1`;	
	if ($output !~ m/error/) {
		($log_level >> $DEBUG) && print "DEBUG traffic_line run successful.\n";
		if ($syncds_update == $UPDATE_TROPS_NEEDED) {
			$syncds_update = $UPDATE_TROPS_SUCCESSFUL;
		}
	}
	else {
		if ($syncds_update == $UPDATE_TROPS_NEEDED) {
			($log_level >> $ERROR) && print "ERROR traffic_line run failed. Updating Traffic Ops anyway.\n";
			$syncds_update = $UPDATE_TROPS_SUCCESSFUL;
		}
		else {
			($log_level >> $ERROR) && print "ERROR traffic_line run failed.\n";
		}
	}
}

sub check_plugins {
	my $cfg_file = shift;
	my $file_lines_ref = shift;
	my %file_lines = %$file_lines_ref;
	my $return_code = 0;

	if ($cfg_file eq "plugin.config") {
		($log_level >> $DEBUG) && print "DEBUG Entering advanced processing for plugin.config.\n";
		foreach my $linep (sort keys %file_lines) {
			if ($linep =~ m/^\#/) { next; }		
			(my $plugin_name) = split(/\s+/, $linep);
			$plugin_name =~ s/\s+//g;
			($log_level >> $DEBUG) && print "DEBUG Found plugin $plugin_name in $cfg_file.\n";
			my $return_code = &check_this_plugin($plugin_name);
			if ($return_code == $PLUGIN_YES) {
				($log_level >> $DEBUG) && print "DEBUG Package for plugin: $plugin_name is installed.\n";
			}
			elsif ($return_code == $PLUGIN_NO) {
				($log_level >> $ERROR) && print "ERROR Package for plugin: $plugin_name is not installed!\n";
				$cfg_file_tracker->{$cfg_file}->{'prereq_failed'}++;
			}
		}
	}
	if ($cfg_file eq "remap.config") {
		($log_level >> $DEBUG) && print "DEBUG Entering advanced processing for remap.config\n";
		foreach my $liner (sort keys %file_lines) {
			if ($liner =~ m/^\#/) { next; }		
			(my @parts) = split(/\@/, $liner);
			foreach my $part (@parts) {
				if ($part =~ m/plugin/) {
					(my $dum, my $plugin_name) = split(/\=/, $part);
					$plugin_name =~ s/\s+//g;
					($log_level >> $DEBUG) && print "DEBUG Found plugin $plugin_name in $cfg_file.\n";
					$return_code = &check_this_plugin($plugin_name);
					if ($return_code == $PLUGIN_YES) {
						($log_level >> $DEBUG) && print "DEBUG Package for plugin: $plugin_name is installed.\n";
					}
					elsif ($return_code == $PLUGIN_NO) {
						($log_level >> $ERROR) && print "ERROR Package for plugin: $plugin_name is not installed\n";
						$cfg_file_tracker->{$cfg_file}->{'prereq_failed'}++;
					}
				}
			}
		}
	}
	($log_level >> $TRACE) && print "TRACE Returning $return_code for checking plugins for $cfg_file.\n";
}


sub check_ntp {
	if ($ntpd_restart_needed && $script_mode != $SYNCDS) {
		if ($script_mode == $INTERACTIVE) {
			my $select = 'Y';
			($log_level >> $ERROR) && print "ERROR ntp configuration has changed. 'service ntpd restart' needs to be run. Should I do that now? (Y/[n]):";
			$select = <STDIN>;
			chomp($select);
			if ($select =~ m/Y/) {
				my $status = &restart_service("ntpd");
				($log_level >> $DEBUG) && print "DEBUG 'service ntpd restart' run successful.\n";
			}
			else {
				($log_level >> $ERROR) && print "ERROR ntp configuration has changed, but ntpd was not restarted.\n"; 
			}
		}
		elsif ($script_mode == $BADASS) {
			my $status = &restart_service("ntpd");
			($log_level >> $DEBUG) && print "DEBUG 'service ntpd restart' successful.\n";
		}
	}
	if ($script_mode == $REPORT) {
		open my $fh, '<', "/etc/ntp.conf" || (($log_level >> $ERROR) && print "ERROR Can't open /etc/ntp.conf\n");
		my %ntp_conf_servers = ();
		while (<$fh>) {
			my $line = $_;
			$line =~ s/\s+/ /g;
			$line =~ s/(^\s+|\s+$)//g;
			chomp($line);
			if ($line =~ m/^\#/ || $line =~ m/^$/ ) { next; }
			if ($line =~ m/^server/) {
				(my $dum, my $server) = split(/\s+/, $line);
				($log_level >> $TRACE) && print "TRACE ntp.conf server: ...$line...\n";
				$ntp_conf_servers{$server} = undef;
			}
		}
		close $fh;

		my $ntpq_output = `/usr/sbin/ntpq -pn`;
		my $ntp_peer_found = 0;
		my $ntp_candidate_found = 0;
		(my @ntpq_output_lines) = split(/\n/, $ntpq_output);
		foreach my $nol (@ntpq_output_lines) {
			if ($nol =~ m/refid/ || $nol =~ m/========/) { next; }
			if ($nol !~ m/(\d){1,3}\.(\d){1,3}\.(\d){1,3}\.(\d){1,3}/) { next; }
			$nol =~ s/^\s//;
			($log_level >> $TRACE) && print "TRACE ntpq output line: ...$nol...\n";
			(my $ntpq_server) = split(/\s+/, $nol);
			if ($nol =~ m/\*/) {
				($log_level >> $TRACE) && print "TRACE Found NTP server peer: $ntpq_server\n";
				$ntp_peer_found++;
			}
			elsif ($nol =~ m/\+/) {
				($log_level >> $TRACE) && print "TRACE Found NTP server candidate: $ntpq_server\n";
				$ntp_candidate_found++;
			}
			$ntpq_server =~ s/^\s//;
			$ntpq_server =~ s/^\*//;
			$ntpq_server =~ s/^\-//;
			$ntpq_server =~ s/^\.//;
			$ntpq_server =~ s/^\+//;
			$ntpq_server =~ s/^o//;
			$ntpq_server =~ s/^x//;
			($log_level >> $TRACE) && print "TRACE ntpq server after processing: $ntpq_server\n";
			if ( !exists($ntp_conf_servers{$ntpq_server}) ) {
				($log_level >> $ERROR) && print "ERROR NTP server ($ntpq_server) is in use but is not configured in ntp.conf!\n";
			}
		}
		if (!$ntp_peer_found) {
			($log_level >> $ERROR) && print "ERROR No NTP server peer found!\n";
		}
	}
}

sub check_this_plugin {
	my $plugin = shift;
	my $full_plugin = $TS_HOME . "/libexec/trafficserver/" . $plugin;
	($log_level >> $DEBUG) && print "DEBUG Checking package dependency for plugin: $plugin.\n";
	
	my $provided = package_provides($full_plugin);
	
	if ($provided) {
		if (package_was_installed($provided)) {
			$trafficserver_restart_needed++;
		}

		return($PLUGIN_YES);	
	} else {
		return($PLUGIN_NO);
	}
}

sub curl_me {
	my $url = shift;
	my $retry_counter = 5;
	my $result = `/usr/bin/curl $CURL_OPTS $url 2>&1`;
	($log_level >> $TRACE) && print "TRACE result for $url is: ...$result....\n";

	while ($result =~ m/^curl\: \(\d+\)/ && $retry_counter > 0) {
		$result =~ s/(\r|\c|\f|\t|\n)/ /g;
	    	($log_level >> $WARN) && print "WARN Error receiving $url from Traffic Ops: $result\n";
		$retry_counter--;
		sleep 5;
		$result = `/usr/bin/curl $CURL_OPTS $url 2>&1`;
	}
	if ($result =~ m/^curl\: \(\d+\)/ && $retry_counter == 0) {
    		($log_level >> $FATAL) && print "FATAL $url returned in error from Traffic Ops five times!\n";
		exit 1;
	}
	else {
		($log_level >> $INFO) && print "INFO Success receiving $url from Traffic Ops.\n";
	}

	my (@chars) = split(//, $result);
	my $response_code = pop(@chars) . pop(@chars) . pop(@chars);
	$response_code = reverse($response_code);
	($log_level >> $DEBUG) && print "DEBUG Received $response_code for $url from Traffic Ops.\n";
	if ($response_code >= 400) {
		($log_level >> $ERROR) && print "ERROR Received error code $response_code for $url from Traffic Ops!\n";
		return $response_code;
	}
	for (0..2) { chop($result) };

	if ($url =~ m/\.json$/) {
		eval {
			decode_json($result);
			1;
		} or do {
			my $error = $@;
			($log_level >> $FATAL) && print "FATAL $url did not return valid JSON: $result | error: $error\n";
			exit 1;
		}
	}
	my $size = length($result);
	if ($size == 0) {
		($log_level >> $FATAL) && print "FATAL URL: $url returned empty!! Bailing!\n";
		exit 1;
	} 
	return $result;
}

sub replace_cfg_file {
	my $cfg_file = shift;
	my $return_code = 0;
	my $select = 2;
	if ($script_mode == $INTERACTIVE) {
		($log_level >> $ERROR) && print "ERROR $cfg_file on disk needs updated with one from Traffic Ops. [1] override files on disk with data in Traffic Ops, [2] ignore and continue. (2): ";
		my $input = <STDIN>;
		chomp($input);
		if ($input =~ m/\d/) {
			$select = $input;
		}
	}
	if ( $select == 1 || $script_mode == $BADASS || $script_mode == $SYNCDS ) {
		($log_level >> $ERROR) && print "ERROR Copying $cfg_file_tracker->{$cfg_file}->{'backup_from_trops'} to $cfg_file_tracker->{$cfg_file}->{'location'}/$cfg_file\n";
		system("/bin/cp $cfg_file_tracker->{$cfg_file}->{'backup_from_trops'} $cfg_file_tracker->{$cfg_file}->{'location'}/$cfg_file");
		$cfg_file_tracker->{$cfg_file}->{'change_applied'}++;
		($log_level >> $TRACE) && print "TRACE Setting change applied for $cfg_file.\n";
		$return_code = $CFG_FILE_CHANGED;
		&process_reload_restarts($cfg_file);
	} 
	elsif ( $select == 2 && $script_mode != $REPORT ) {
		($log_level >> $ERROR) && print "ERROR You elected not to replace $cfg_file with version from Traffic Ops.\n";
		$cfg_file_tracker->{$cfg_file}->{'change_applied'} = 0;
		$return_code = $CFG_FILE_UNCHANGED;
	}
	else {
		$cfg_file_tracker->{$cfg_file}->{'change_applied'} = 0;
		$return_code = $CFG_FILE_UNCHANGED;
	}
	return $return_code;
}

sub process_reload_restarts {
	my $cfg_file = shift;	
	if ($cfg_file =~ m/url\_sig\_(.*)\.config/) {
		($log_level >> $DEBUG) && print "DEBUG New keys were installed in: $cfg_file. Later I will attempt to touch remap.config.\n";
		$installed_new_keys++;
	}
	elsif ($cfg_file =~ m/hdr\_rw\_(.*)\.config/) {
		($log_level >> $DEBUG) && print "DEBUG New/changed header rewrite rule, installed in: $cfg_file. Later I will attempt to touch remap.config.\n";
		$new_header_rewrite++;
	}
	elsif ($cfg_file eq "plugin.config" || $cfg_file eq "50-ats.rules") {
		($log_level >> $DEBUG) && print "DEBUG $cfg_file changed, trafficserver restart needed.\n";
		$trafficserver_restart_needed++;
	}
	elsif ($cfg_file_tracker->{$cfg_file}->{'location'} =~ m/trafficserver/) {
		($log_level >> $DEBUG) && print "DEBUG $cfg_file changed, traffic_line needed.\n";
		$traffic_line_needed++;
	}
	elsif ($cfg_file eq "sysctl.conf") {
		($log_level >> $DEBUG) && print "DEBUG $cfg_file changed, 'sysctl -p' needed.\n";
		$sysctl_p_needed++;
	}
	elsif ($cfg_file eq "ntpd.conf") {
		($log_level >> $DEBUG) && print "DEBUG $cfg_file changed, ntpd restart needed.\n";
		$ntpd_restart_needed++;
	}
	elsif ($cfg_file =~ m/\_facts/) {
		($log_level >> $DEBUG) && print "DEBUG Puppet facts file $cfg_file changed.\n";
		$UPDATE_TROPS_SUCCESSFUL = 1;
	}
}

sub check_output {
	my $out = shift;
	if (defined($out)) {
		$out =~ s/(\n+|\t+|\r+|\s+)/ /g;
		if ($out =~ m/error/i) {
			($log_level >> $ERROR) && print "ERROR $out\n";
			return 1;
		}
		else {
			return 0;
		}
	}
	else {
		return 1;
	}
}

sub get_cookie {
    my $tm_host  = shift;
    my $tm_login = shift;
    my ( $u, $p ) = split( /:/, $tm_login );

    my $cmd = "curl -vLks -X POST -d 'u=" . $u . "' -d 'p=" . $p . "' " . $tm_host . "/login -o /dev/null 2>&1 | grep Set-Cookie | awk '{print \$3}'";
	($log_level >> $DEBUG) && print "DEBUG Getting cookie with $cmd.\n";
    my $cookie = `$cmd`;
    chomp $cookie;
    $cookie =~ s/;$//;
	if ($cookie =~ m/mojolicious/) {
		($log_level >> $DEBUG) && print "DEBUG Cookie is $cookie.\n";
    	return $cookie;
	}
	else {
		($log_level >> $ERROR) && print "ERROR Cookie not found from Traffic Ops!\n";
		return 0;
	}
}

sub check_script_mode {
	#### No default script mode
	my $script_mode = undef;
	if ($ARGV[0] eq "interactive") {
		($log_level >> $DEBUG) && print "DEBUG Script running in interactive mode.\n";
		$script_mode = 0;
	}
	elsif ($ARGV[0] eq "report" ) {
		($log_level >> $DEBUG) && print "DEBUG Script running in report mode.\n";
		$script_mode = 1;
	}
	elsif ($ARGV[0] eq "badass" ) {
		($log_level >> $DEBUG) && print "DEBUG Script running in badass mode.\n";
		$script_mode = 2;
	}
	elsif ($ARGV[0] eq "syncds" ) {
		($log_level >> $DEBUG) && print "DEBUG Script running in syncds mode.\n";
		$script_mode = 3;
	}
	else {
		($log_level >> $FATAL) && print "FATAL You did not specify a valid mode. Exiting.\n";
		&usage();
		exit 1;
	}
	return $script_mode;

}

sub check_run_user {
	my $run_user = `/usr/bin/id`;
	chomp($run_user);
	if ( ($run_user !~ m/uid\=0\(root\)/ && $run_user !~ m/gid\=0\(root\)/ && $run_user !~ m/groups\=0\(root\)/) && ($script_mode == $INTERACTIVE || $script_mode == $BADASS || $script_mode == $SYNCDS) ) {
		($log_level >> $FATAL) && print "FATAL For interactive, badass, or syncds mode, you must run script as root user. Exiting.\n";
		exit 1;
	}
	else {
		($log_level >> $TRACE) && print "TRACE run user is $run_user.\n";
	}
}

sub check_log_level {
	if ( ($script_mode == $INTERACTIVE) && !($log_level >> $ERROR) ) {
		print "FATAL Sorry, for interactive mode, the log level must be at least ERROR, exiting.\n";
		exit 1;
	}
}

sub set_domainname {
	my $hostname = `cat /etc/sysconfig/network | grep HOSTNAME`; 
	chomp($hostname);
	$hostname =~ s/HOSTNAME\=//g;
	my $domainname;
	(my @parts) = split (/\./, $hostname);
	for (my $i=1;$i<scalar(@parts);$i++) {
		$domainname .= $parts[$i] . ".";
	}
	$domainname =~ s/\.$//g;
	return $domainname;
}

sub get_cfg_file_list {
	my $host_name = shift;
	my $tm_host = shift;
	my $cfg_files;
	my $profile_name;
	my $cdn_name;
	my $url = "$tm_host/ort/$host_name/ort1";

	my $result = &curl_me($url);

	if ($result =~ m/^\d{3}$/) {
		($log_level >> $FATAL) && print "FATAL ORT URL: $url returned $result. Cannot continue; bailing.\n";
		exit 1;
	}

	my $ort_ref = decode_json($result);
	$profile_name = $ort_ref->{'profile'}->{'name'};
	($log_level >> $INFO) && printf ("INFO Found profile from Traffic Ops: $profile_name\n");
	$cdn_name = $ort_ref->{'other'}->{'CDN_name'};
	($log_level >> $INFO) && printf ("INFO Found CDN_name from Traffic Ops: $cdn_name\n");
	foreach my $cfg_file ( sort keys %{$ort_ref->{'config_files'}} ) {
		($log_level >> $INFO) && printf ("INFO Found config file: %-30s with location: %-50s\n", $cfg_file, $ort_ref->{'config_files'}->{$cfg_file}->{'location'});
		$cfg_files->{$cfg_file}->{'location'} = $ort_ref->{'config_files'}->{$cfg_file}->{'location'};
	}
	return ($profile_name, $cfg_files, $cdn_name);
}

sub get_header_comment {
	my $to_host = shift;
	my $toolname;

	my $url = "$to_host/api/1.1/system/info.json";
	my $result = &curl_me($url);

	if ($result =~ m/^\d{3}$/) {
		($log_level >> $ERROR) && print "ERROR System Info URL: $url returned $result.\n";
		return "";
	}

	my $result_ref = decode_json($result);
   	if (defined($result_ref->{'response'}->{'parameters'}->{'tm.toolname'})) {
		$toolname = $result_ref->{'response'}->{'parameters'}->{'tm.toolname'};
		($log_level >> $INFO) && printf ("INFO Found tm.toolname: $toolname\n");
	}
	else {
		print "ERROR Did not find tm.toolaname!\n";
		$toolname = "";
	}
	return $toolname;

}

sub __package_action {
	my $action = shift;
	my @argument_list = @_;
	
	my $arguments = join(" ", @argument_list);
	my $yum_command = "/usr/bin/yum $YUM_OPTS $action $arguments 2>&1";
	my $out = `$yum_command`;	

	# yum exits 0 if successful
	if ($? != 0) {
		($log_level >> $ERROR) && print "ERROR Execution of $yum_command failed!\n";
		($log_level >> $ERROR) && print "ERROR Output: $out\n";
		
		return(0);
	} else {
		($log_level >> $TRACE) && print "TRACE Successfully executed $yum_command\n";
		#($log_level >> $DEBUG) && print "DEBUG Output: $out\n";
		
		return(1);
	}
}

sub get_full_package_name {
	my $package = shift;
	my $version = shift;
	return($package . "-" . $version);
}

sub package_provides {
	my $filename = shift || die("Please supply the full path to the file to verify");
	
	my $out = `/bin/rpm -qf $filename 2>&1`;
	
	if (defined($out)) {
		chomp($out);
	}
	
	if ($? == 0) {
		# return package name that provides $filename
		return($out);
	} else {
		return(0);
	}
}

sub package_requires {
	my $package_name = shift;
	my @package_list = ();

	my $out = `/bin/rpm -q --whatrequires $package_name 2>&1`;
	
	if (defined($out)) {
		chomp($out);
	}
	
	if ($? == 0) {
		@package_list = split(/\n/, $out);
	}
	
	return(@package_list);
}

sub package_was_installed {
	my $package_name = shift;
	
	if (exists($install_tracker{$package_name})) {
		($log_level >> $TRACE) && print "TRACE $package_name was installed during this run, returning true\n";
		return(1);
	} else {
		($log_level >> $TRACE) && print "TRACE $package_name was not installed during this run, returning false\n";
		return(0);
	}
}

sub package_installed {
	my $package_name = shift;
	my $package_version = shift;
	my @package_list = ();
	
	if (defined($package_version)) {
		$package_name = $package_name . "-" . $package_version;
	}
	
	my $out = `/bin/rpm -q $package_name 2>&1`;
	
	# rpm returns 0 if installed, 1 if not installed
	if ($? == 0) {
		# installed
		# remove the newlines (hence not using an array for $out)
		@package_list = split(/\n/, $out);
	}
	
	return(@package_list);
}

sub packages_available {
	my @package_list = @_;
	my $package_missing = 0;
	
	for my $package (@package_list) {
		my $result = __package_action("info", $package);
		
		if ($result) {
			($log_level >> $TRACE) && print "TRACE $package is available\n";
		} else {
			($log_level >> $ERROR) && print "ERROR $package is not available in the yum repo(s)!\n";
			$package_missing = 1;
		}
	}
	
	if ($package_missing) {
		return(0);
	} else {
		return(1);
	}
}

sub install_packages {
	my @package_list = @_;
	
	if (__package_action("install", "-y", @package_list)) {
		for my $pkg (@package_list) {
			$install_tracker{$pkg} = 1;
		}

		return(1);
	} else {
		return(0);
	}
}

sub remove_packages {
	my @package_list = @_;
	
	return(__package_action("remove", "-y", @package_list));
}

sub process_packages {
	my $host_name = shift;
	my $tm_host = shift;
	
	my $proceed = 0;
	my $url = "$tm_host/ort/$host_name/packages";
	my $result = &curl_me($url);
	
	if (defined($result) && $result ne "" && $result !~ m/^(\d){3}$/) {
		my %package_map;
		my @package_list = @{decode_json($result)};
		
		# iterate through to build the uninstall list
		for my $package (@package_list) {
			my $full_package = get_full_package_name($package->{"name"}, $package->{"version"});
			
			# check to see if any package is installed that has this package's basename (no version)
			for my $installed_package (package_installed($package->{name})) {
				if (exists($package_map{"uninstall"}{$full_package})) {
					($log_level >> $INFO) && print "INFO $full_package: Already marked for removal.\n";
					next;
				} elsif ($installed_package eq $full_package) {
					# skip this package if it's the correct version
					($log_level >> $INFO) && print "INFO $full_package: Currently installed and not marked for removal.\n";
					next;
				}

				if ($script_mode == $REPORT) {
					($log_level >> $FATAL) && print "ERROR $installed_package: Currently installed and needs to be removed.\n";
				} else {
					($log_level >> $TRACE) && print "TRACE $installed_package: Currently installed, marked for removal.\n";
				}
				
				$package_map{"uninstall"}{$installed_package} = 1;
				
				# add any dependent packages to the list of packages to uninstall
				for my $dependent_package (package_requires($package->{name})) {
					if ($script_mode == $REPORT) {
						($log_level >> $FATAL) && print "ERROR $dependent_package: Currently installed and depends on " . $package->{name} . "and needs to be removed.\n";
					} else {
						($log_level >> $TRACE) && print "TRACE $dependent_package: Currently installed and depends on " . $package->{name} . ", marked for removal.\n";
					}

					$package_map{"uninstall"}{$dependent_package} = 1;
				}
			}
		}
		
		# iterate through to build the install list
		for my $package (@package_list) {
			my $full_package = get_full_package_name($package->{"name"}, $package->{"version"});
			if (!package_installed($package->{name}, $package->{version})) {
				if ($script_mode == $REPORT) {
					($log_level >> $FATAL) && print "ERROR $full_package: Needs to be installed.\n";
				} else {
					($log_level >> $TRACE) && print "TRACE $full_package: Needs to be installed.\n";
				}
				
				$package_map{"install"}{$full_package} = 1;
			} elsif (exists($package_map{"uninstall"}{$full_package})) {
				if ($script_mode == $REPORT) {
					($log_level >> $FATAL) && print "ERROR $full_package: Marked for removal and needs to be installed.\n";
				} else {
					($log_level >> $TRACE) && print "TRACE $full_package: Marked for removal and needs to be installed.\n";
				}
				
				$package_map{"install"}{$full_package} = 1;
			} else {
				# if the correct version is already installed not marked for removal we don't want to do anything..
				if ($script_mode == $REPORT) {
					($log_level >> $INFO) && print "INFO $full_package: Currently installed and not marked for removal.\n";
				} else {
					($log_level >> $TRACE) && print "TRACE $full_package: Currently installed and not marked for removal.\n";
				}
			}
		}
		
		my @install_packages = keys(%{$package_map{"install"}});
		my @uninstall_packages = keys(%{$package_map{"uninstall"}});

		if (scalar(@install_packages) > 0 || scalar(@uninstall_packages) > 0) {

			if (packages_available(@install_packages)) {
				my $uninstalled = (scalar(@uninstall_packages) > 0) ? 0 : 1;
				($log_level >> $TRACE) && print "TRACE All packages available.. proceeding..\n";
				
				if ($script_mode == $BADASS) {
					$proceed = 1;
				} elsif ($script_mode == $INTERACTIVE && scalar(@uninstall_packages) > 0) {
					($log_level >> $INFO) && print "INFO The following packages must be uninstalled before proceeding:\n  - " . join("\n  - ", @uninstall_packages) . "\n";
					if (get_answer("Should I uninstall them now?") && get_answer("Are you sure you want to proceed with the uninstallation?")) {
						$proceed = 1;
					} else {
						$proceed = 0;
					}
				}
				
				if ($proceed && scalar(@uninstall_packages) > 0) {
					if (remove_packages(@uninstall_packages)) {
						($log_level >> $INFO) && print "INFO Successfully uninstalled the following packages:\n  - " . join("\n  - ", @uninstall_packages) . "\n";
						$uninstalled = 1;
					} else {
						($log_level >> $ERROR) && print "ERROR Unable to uninstall the following packages:\n  - " . join("\n  - ", @uninstall_packages) . "\n";
						$proceed = 0;
					}
				}
				
				if ($uninstalled && $script_mode == $INTERACTIVE && scalar(@install_packages) > 0) {
					($log_level >> $INFO) && print "INFO The following packages must be installed:\n  - " . join("\n  - ", @install_packages) . "\n";
					if (get_answer("Should I install them now?") && get_answer("Are you sure you want to proceed with the installation?")) {
						$proceed = 1;
					} else {
						$proceed = 0;
					}
				}
				
				if ($uninstalled && $proceed && scalar(@install_packages) > 0) {
					if (install_packages(@install_packages)) {
						($log_level >> $INFO) && print "INFO Successfully installed the following packages:\n  - " . join("\n  - ", @install_packages) . "\n";
						$syncds_update = $UPDATE_TROPS_SUCCESSFUL;
					} else {
						($log_level >> $ERROR) && print "ERROR Unable to install the following packages:\n  - " . join("\n  - ", @install_packages) . "\n";
					}
				} elsif (scalar(@install_packages) == 0) {
					($log_level >> $INFO) && print "INFO All of the required packages are installed.\n";
				}
			} else {
				($log_level >> $ERROR) && print "ERROR Not all of the required packages are available in the configured yum repo(s)!\n";
			}
		} else {
			if ($script_mode == $REPORT) {
				($log_level >> $INFO) && print "INFO All required packages are installed.\n";
			} else {
				($log_level >> $TRACE) && print "TRACE All required packages are installed.\n";
			}
		}
	}
	else {
		($log_level >> $FATAL) && print "FATAL Error getting package list from Traffic Ops!\n";
		exit 1;
	}
}

sub set_chkconfig {
	my $service = shift;
	my $run_level = shift;
	my $setting = shift;
	
	if (!defined($service) || !defined($run_level) || !defined($setting)) {
		die("Please supply a service, run level (0-6) and setting, in that order");
	} elsif ($run_level !~ m/^[0-6]$/) {
		die("Please supply a numeric run level (0-6)");
	}
	
	my $command = "/sbin/chkconfig --level $run_level $service $setting";
	my $output = `$command 2>&1`;
	
	chomp($output);
	
	($log_level >> $TRACE) && print "TRACE $command returned $?, output: $output\n";
	
	if ($? == 0) {
		return(1);
	} else {
		return(0);
	}
}

sub chkconfig_matches {
	my $service = shift || die("Please supply a service");
	my $service_settings = shift || die("Please supply a chkconfig string to verify");
	
	($log_level >> $TRACE) && print "TRACE Checking whether ${service}'s chkconfig output matches $service_settings.\n";
	
	my $command = "/sbin/chkconfig --list $service";
	my $output = `$command 2>&1`;
	chomp($output);
	
	if ($? == 0) {
		if ($output =~ m/^$service\s+$service_settings$/) {
			($log_level >> $INFO) && print "INFO chkconfig output for $service matches $service_settings.\n";
			return(1);
		} else {
			($log_level >> $ERROR) && print "ERROR chkconfig output for $service does not match what we expect...\n";
			($log_level >> $TRACE) && print "TRACE $output != $service_settings.\n";
			return(0);
		}
	} else {
		($log_level >> $ERROR) && print "ERROR $command returned non-zero ($?), output: $output.\n";
		
		return(0);	
	}
}

sub process_chkconfig {
	my $host_name = shift;
	my $tm_host = shift;
	
	my $proceed = 0;
	my $url = "$tm_host/ort/$host_name/chkconfig";
	my $result = &curl_me($url);
	
	if (defined($result) && $result ne "" && $result !~ m/^\d{3}$/) {
		my @chkconfig_list = @{decode_json($result)};
		
		for my $chkconfig (@chkconfig_list) {
			if (package_installed($chkconfig->{"name"})) {
				if (!chkconfig_matches($chkconfig->{"name"}, $chkconfig->{"value"})) {
					if ($script_mode == $BADASS || $script_mode == $INTERACTIVE) {
						my $fixit = 0;
						
						if ($script_mode == $INTERACTIVE) {
							if (get_answer("Are you sure you would like to correct chkconfig for $chkconfig->{name}?")) {
								$fixit = 1;
							}
						} else {
							$fixit = 1;
						}
						
						if ($fixit) {
							my (@levels) = split(/\s+/, $chkconfig->{"value"});
							
							if (scalar(@levels) == 7) {
								($log_level >> $TRACE) && print "TRACE $chkconfig->{name}: Split chkconfig into " . join(", ", @levels) . "\n";
								
								for my $level (@levels) {
									my ($run_level, $setting) = split(/:/, $level);
									
									if (defined($run_level) && defined($setting)) {
										($log_level >> $TRACE) && print "TRACE $chkconfig->{name}: Setting run level $run_level to $setting\n";
										
										if (!set_chkconfig($chkconfig->{"name"}, $run_level, $setting)) {
											($log_level >> $ERROR) && print "ERROR $chkconfig->{name}: Unable to set run level $run_level to $setting!\n";	
										}
									} else {
										($log_level >> $ERROR) && print "ERROR $chkconfig->{name}: $level is not what we expected!\n";
									}	
								}
								
								if (chkconfig_matches($chkconfig->{"name"}, $chkconfig->{"value"})) {
									($log_level >> $INFO) && print "INFO Successfully set chkconfig for $chkconfig->{name}.\n";
								} else {
									($log_level >> $ERROR) && print "FATAL Unable to set chkconfig values for $chkconfig->{name}!\n";
								}
							} else {
								($log_level >> $ERROR) && print "ERROR $chkconfig->{name}: $chkconfig->{value} is not what we expected!\n";
							}
						}
					} elsif ($script_mode == $REPORT) {
						($log_level >> $INFO) && print "INFO chkconfig for $chkconfig->{name} DOES NOT MATCH $chkconfig->{value}.\n";
					}
				} else {
					if ($script_mode == $REPORT) {
						($log_level >> $INFO) && print "INFO chkconfig for $chkconfig->{name} matches $chkconfig->{value}.\n";
					} else {
						($log_level >> $TRACE) && print "TRACE chkconfig for $chkconfig->{name} matches $chkconfig->{value}.\n";
					}
				}
			} else {
				($log_level >> $ERROR) && print "ERROR $chkconfig->{name} is not installed!\n";
			}
		}
	} else {
		($log_level >> $ERROR) && print "ERROR No chkconfig parameters returned.\n";
	}
}

sub get_answer {
	my $question = shift || die("Please supply a question");
	
	my $answer = "";
	
	while ($answer !~ /^(y|n)$/i) {
		($log_level >> $INFO) && print "INFO $question [Y/n]: ";
		$answer = <STDIN>;
		chomp($answer);
	}
	
	if ($answer =~ /^y$/i) {
		return(1);
	} else {
		return(0);
	}
}

sub start_restart_services {
	#### Start ATS
	if (package_installed("trafficserver")) {
		($log_level >> $DEBUG) && print "DEBUG trafficserver is installed.\n";
		$ats_running = &start_service("trafficserver");
		if ($ats_running == $START_SUCCESSFUL) {
			$traffic_line_needed = 0;
			($log_level >> $DEBUG) && print "DEBUG trafficserver was just started, no need to run $TRAFFIC_LINE -x.\n";
		}
		elsif ($ats_running == $START_FAILED) {
			$traffic_line_needed = 0;
			($log_level >> $DEBUG) && print "DEBUG trafficserver failed to start, running $TRAFFIC_LINE -x will also fail.\n";
		}
		elsif ($ats_running == $START_NOT_ATTEMPTED) {
			($log_level >> $DEBUG) && print "DEBUG trafficserver was not attempted to be started.\n";
		}
	}

	#### Advanced ATS processing
	if ($ats_running == $ALREADY_RUNNING && $traffic_line_needed && !$trafficserver_restart_needed ) {
		if ($script_mode == $REPORT) {
			($log_level >> $ERROR) && print "ERROR ATS configuration has changed. '$TRAFFIC_LINE -x' needs to be run.\n";	
		}
		elsif ($script_mode == $BADASS || $script_mode == $SYNCDS) {
			($log_level >> $ERROR) && print "ERROR ATS configuration has changed. Running '$TRAFFIC_LINE -x' now.\n";
			&run_traffic_line();
		}
		elsif ($script_mode == $INTERACTIVE) {
			my $select = 'n';
			($log_level >> $ERROR) && print "ERROR ATS configuration has changed. '$TRAFFIC_LINE -x' needs to be run. Should I do that now? (Y/[n]):";
			$select = <STDIN>;
			chomp($select);
			if ($select =~ m/Y/) {
				&run_traffic_line();
				($log_level >> $DEBUG) && print "DEBUG traffic_line run successful.\n";
				if ($syncds_update == $UPDATE_TROPS_NEEDED) {
					$syncds_update = $UPDATE_TROPS_SUCCESSFUL;
				}
			}
			else {
				($log_level >> $ERROR) && print "ERROR ATS configuration has changed. '$TRAFFIC_LINE -x' was not run.\n"; 
				if ($syncds_update == $UPDATE_TROPS_NEEDED) {
					($log_level >> $ERROR) && print "ERROR $TRAFFIC_LINE -x was not run, so Traffic Ops was not updated!\n"; 
					$syncds_update = $UPDATE_TROPS_FAILED;
				}
			}
		}
	}
	elsif ($traffic_line_needed && ($ats_running == $START_FAILED || $ats_running == $START_NOT_ATTEMPTED)) {
		($log_level >> $ERROR) && print "ERROR ATS configuration has changed. The new config will be picked up the next time ATS is started.\n";	
		if ($syncds_update == $UPDATE_TROPS_NEEDED) {
			($log_level >> $ERROR) && print "ERROR $TRAFFIC_LINE -x was not run, but Traffic Ops is being updated anyway.\n"; 
			$syncds_update = $UPDATE_TROPS_SUCCESSFUL;
		}
	}
	elsif ($ats_running && $trafficserver_restart_needed) {
		if ($script_mode == $REPORT) {
			($log_level >> $ERROR) && print "ERROR ATS configuration has changed, trafficserver needs to be restarted (service trafficserver restart).\n";	
		}
		elsif ($script_mode == $INTERACTIVE) {
			my $select = 'n';
			($log_level >> $ERROR) && print "ERROR ATS configuration has changed, trafficserver needs to be restarted. Should I do that now? (Y/[n]):";	
			$select = <STDIN>;
			chomp($select);
			if ($select =~ m/Y/) {
				my $result = &restart_service("trafficserver");	
			}
			else {
				($log_level >> $ERROR) && print "ERROR ATS configuration has changed, but trafficserver was not restarted.\n"; 
			}
		}
		elsif ($script_mode == $BADASS) {
			($log_level >> $ERROR) && print "ERROR ATS configuration has changed, trafficserver needs to be restarted.\n";	
			my $result = &restart_service("trafficserver");	
		}
	}
	#### End processing ATS
	
}

sub run_sysctl_p {

	if ($script_mode == $INTERACTIVE) {
		my $select = 'n';
		($log_level >> $ERROR) && print "ERROR sysctl configuration has changed. 'sysctl -p' needs to be run. Should I do that now? (Y/[n]):";
		$select = <STDIN>;
		chomp($select);
		if ($select =~ m/Y/) {
			my $out = `sysctl -p 2>&1`;
			my $return = &check_output($out);
			if (!$return) {
				($log_level >> $DEBUG) && print "DEBUG sysctl -p run successful.\n";
			}
			else {
				($log_level >> $ERROR) && print "ERROR sysctl -p failed.\n";
			}
		}
		else {
			($log_level >> $ERROR) && print "ERROR sysctl configuration has changed. 'sysctl -p' was not run.\n"; 
		}
	}
	elsif ($script_mode == $BADASS) {
		my $out = `sysctl -p 2>&1`;
		my $return = &check_output($out);
		if (!$return) {
			($log_level >> $DEBUG) && print "DEBUG sysctl -p run successful.\n";
		}
		else {
			($log_level >> $ERROR) && print "ERROR sysctl -p failed.\n";
		}
	}
}

{
	my $fh;
	sub check_only_copy_running {
		return if $fh;
		open $fh, '<', $0 or die $!; 

		unless (flock($fh, LOCK_EX|LOCK_NB)) {
			($log_level >> $FATAL) && print "FATAL $0 is already running. Exiting.\n";
			exit 1;
		} 
	}
}