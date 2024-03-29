#!/usr/bin/perl
#    __      _        _____                        _ _              
#   /__\ __ (_) ___  /__   \_   _ _ __  _ __   ___| (_)_______ _ __ 
#  /_\| '_ \| |/ __|   / /\/ | | | '_ \| '_ \ / _ \ | |_  / _ \ '__|
# //__| |_) | | (__   / /  | |_| | | | | | | |  __/ | |/ /  __/ |   
# \__/| .__/|_|\___|  \/    \__,_|_| |_|_| |_|\___|_|_/___\___|_|   
#     |_|                                                           
#
# http://sourceforge.net/projects/epictunnelizer/
#
# ============================================================================
#
# This project is an improvement of HTTPTunnelizer by Sebastian Weber, more info
# at: http://http-tunnel.sourceforge.net/
#
# Copyright (c) 2005-2011 Artica Soluciones Tecnologicas
# Please see http://sourceforge.net/projects/epictunnelizer/ for full contribution 
# list
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public License
# as published by the Free Software Foundation; version 2
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.

#!/usr/bin/perl

use warnings;

use Data::Dumper;
use ProxyConfig;
use ProxyLib;
use RequestLog;
use ProxySelector;
use Time::HiRes qw( time usleep);
use Thread::Semaphore;

THE_BEG:
# globals in all threads
# $LL
# $cfg
$CONFIG_FILENAME="central_proxy.cfg";

our %loglistener : shared = ();
@globalstatus = ();

# check threads version
if (threads->VERSION<1.5) {
	print "WARNING: At least threads version 1.50 is required. Current: ".threads->VERSION."\n";
}

# do we have any command line arguments?
for (@ARGV) {
	if (m/^-[^-]/) {
		print "Proxy Client ".REL_VERSION." (c) ".REL_YEAR." Artica ST, contact: info [at] artica [dot] es\n";
		print "usage: $0 [<configfile>] [--debug] [--<param>=<value> ...]\n";
		exit 1;	
	} elsif (!m/^--/) {$CONFIG_FILENAME=$_;}
}

# read the config file
$cfg=readconfig ($CONFIG_FILENAME);

# override config settings from commandline
for (@ARGV) {m/^--(.*?)(=(.*))?$/ and $cfg->{"\U$1"}=defined($2)?$3:1;}
$LL=$cfg->{LOGLEVEL};

# load some optional modules: Compress::Zlib
$cfg->{MOD_ZLIB_AVAILABLE}=eval("require Compress::Zlib");
if (!$cfg->{MOD_ZLIB_AVAILABLE} && $cfg->{ENABLE_ZLIB}) {
	push (@globalstatus,"ERROR: Module Compress::Zlib could not be loaded - please install or disable data compression");
	$cfg->{ENABLE_ZLIB}=0;}
if ($cfg->{MOD_ZLIB_AVAILABLE}) {import Compress::Zlib ':DEFAULT';}
$cfg->{MOD_ZLIB_LOADED}=$cfg->{MOD_ZLIB_AVAILABLE};

# spawn logging thread
if ($LL) {
	$logqueue=Thread::Queue->new();
	$log_t=threads->create("thread_log_main");
	logline ("---------------------------------------------------------------------",1,0);
	logline ("Initializing Proxy Client",1,0);
}

# check configuration
if ($cfg->{DATA_SEND_MAXSIMCONN}<1) {
	push (@globalstatus,"Configuration error: DATA_SEND_MAXSIMCONN needs to be at least 1");
	$cfg->{DATA_SEND_MAXSIMCONN}=1;
}

# load optional modules: Crypt::OpenSSL
$cfg->{MOD_RSA_AVAILABLE}=eval("require Crypt::OpenSSL::RSA")&& eval("require Mcrypt");
if ($cfg->{ENCRYPTION}) {
	if (!$cfg->{MOD_RSA_AVAILABLE}) {
		push (@globalstatus,"ERROR: Modules for encrytion support could not be loaded - please install or disable data encryption");
		$cfg->{ENCRYPTION}=0;
	} else {import Crypt::OpenSSL::RSA ':DEFAULT'; import Mcrypt ':DEFAULT';}
}

# global variables
# server socket descriptors:
#	$server_sockets(fileno)= {
#		fd => socket filedesc
#		rname => remote server name
#		port => local port
#		rport => remote port
#		desc => decription
%server_sockets=(); 
$sendqueue=Thread::Queue->new();	# for the outbound data
$syncqueue=Thread::Queue->new();	# for syncing the main listening thread with the client serving thread
$conqueue=Thread::Queue->new();
$waitqueue=Thread::Queue->new();
$countqueue=Thread::Queue->new();
$restartq=Thread::Queue->new();
our %outqueue : shared = ();
our %connection_ids : shared = ();
our %t_status : shared = ();
our %t_type : shared = ();
our $id_access : shared = "";
our $id_ban : shared = "";

#Monitoring semaphore
my $sem :shared = Thread::Semaphore->new (1);
my %net_stats :shared;

eval{$tpaddr   = inet_aton($cfg->{PROXY_SERVER}?$cfg->{PROXY_SERVER}:$cfg->{SERVER});};
if ($tpaddr) {
	$tpaddr   = sockaddr_in($cfg->{PROXY_SERVER}?$cfg->{PROXY_PORT}:$cfg->{PORT}, $tpaddr);
	
	# open the portmap and socks listening sockets
	$cfg->{SOCKS_ENABLED} and $cfg->{PORTMAP}.="\n".($cfg->{SOCKS_IF}?$cfg->{SOCKS_IF}.":":"").$cfg->{SOCKS_PORT}." S S S\n";
	for $i (split(/\n/, $cfg->{PORTMAP})) {
		$i=~m/^\s*(((\S+):)?(\S+))\s+(\S+)\s+(\S+)\s+(.+)\s*$/ or next;
		$s_fd="SERVER".$4;
		if ($msg=openserverport ($s_fd,$4,$3?inet_aton($3):"")) {
			push (@globalstatus,"Server socket on port $1: $msg");
			next;
		}
		$server_sockets{fileno($s_fd)}={
			fd		=> $s_fd,
			port	=> $4,
			rname	=> $5,
			rport	=> $6,
			desc	=> $7};
		if ($6 eq "S") {$LL and logline ("Opening SOCKS server socket on port $1");}
		else {$LL and logline ("Opening server socket on port $1 -> $5:$6 ($7)");}
	}
} else {
	push (@globalstatus,"Could not resolve ".($cfg->{PROXY_SERVER}?$cfg->{PROXY_SERVER}:$cfg->{SERVER})."!");
}

#starting request log
start_request_log ($cfg);

#setup proxy selector
$sat_proxies = setup_proxy_selector($cfg);

# Set up encryption
if ($cfg->{ENCRYPTION}) {
	$rsa = Crypt::OpenSSL::RSA->generate_key(1024);
	$rsa->use_pkcs1_oaep_padding();
	$pubkey=$rsa->get_public_key_x509_string();
	$pubkey=~s/-----.*?-----|\n|\r|=//g;
}

# Create monitoring thread
if ($cfg->{MONITORING_ENABLED}) {
	$mon_thread = threads->create("monitoring");
	$mon_thread->detach();
}

# Spawn the sending threads
for ($i=0; $i<$cfg->{DATA_SEND_MAXSIMCONN}; $i++) {threads->create("o_thread");}
# Spawn the permanent client listener threads
for ($i=0; $i<$cfg->{THREADS}; $i++) {threads->create("c_thread");}

# Signal handlers
$SIG{INT}=$SIG{TERM}=$SIG{HUP}=\&connection_exit;
$SIG{PIPE}=\&connection_restart;
if (@globalstatus) {for (@globalstatus) {logline($_,$LL,1);}}
keys(%server_sockets) or die "Proxy client startup failed";
logline ("Proxy client started and accepting connections",$LL,1);

# now, listen and accept connections on all the ports
# set up the handles to select on
$rin=pack("B*", "0"x64);
for $i (keys(%server_sockets)) {vec($rin,$i,1)=1;}
for (;;) {
	while (select ($rout=$rin,undef,undef,1)==-1) {}
	for (handles($rout)) {
		# if a client thread is available, signal to accept the new connection and
		# wait until the client accepted
		# if none is available, we need to spawn a new client thread
		if ($waitqueue->pending) {
			$conqueue->enqueue($_);
			$syncqueue->dequeue;
		} else {
			if ($cfg->{MAXTHREADS}<=0 || $countqueue->pending <= $cfg->{MAXTHREADS}) {
				threads->create("c_thread",$_);
				$syncqueue->dequeue;
			} else {
				# refuse the connection
				$LL>=2 and logline("WARNING: Too many connections - refusing connection");
				accept(CLIENT,$server_sockets{$_}->{fd});
				shutdown (CLIENT,2); close (CLIENT);
			}
		}
	}
	if ($restartq->pending()) {
		connection_cleanup ($restartq->dequeue);
		goto THE_BEG;
	}
	
	#Refresh selectors if needed
	$sat_proxies = refresh_selector($cfg, $sat_proxies);
}

#####
## updates net statistics
#####

sub update_net_stats($$$) {
	my ($ip, $bytes, $type) = @_;
	
	### BLOCK for write ###
	$sem->down();	

	if (!defined($net_stats{$ip})) {
		my %aux_hash :shared = (SEND , 0 , RECV , 0, REQ, 0);
		$net_stats{$ip} = \%aux_hash;
	}

	#Add one to request
	$net_stats{$ip}->{REQ}++;
	
	if ($type eq "send") {
		$net_stats{$ip}->{SEND} = $net_stats{$ip}->{SEND} + $bytes;
	} elsif ($type eq "recv") {
		$net_stats{$ip}->{RECV} = $net_stats{$ip}->{RECV} + $bytes;
	}

	### RELEASE for write ###
	$sem->up();		
}

#####
## create pandora xml to monitor the net_stats
#####
sub dump_net_stats() {
	
	$total_request = 0;
	$total_send = 0;
	$total_recv = 0;
	
	### BLOCK for write ###
	$sem->down();	
	
	my $agent_group = $cfg->{MONITORING_GROUP};	
	
	# Generate stats for each IP
	foreach my $ip (keys %net_stats){
		my $time = time();
		
		$time =~ s/\..+//; 
		
		@date = localtime($time);
			
		$str_date = strftime("%Y/%m/%d %H:%M:%S", @date);
		
		my $agent_name = $cfg->{MONITORING_PREFIX}.$ip;
		
		open(FD, ">", "pandora_data/".$agent_name."_".$time.".data");
			
		print FD "<?xml version='1.0' encoding='ISO-8859-1'?>\n";
		print FD "<agent_data os_name='Other' os_version='1' group='$agent_group'
					interval='300' version='1' timestamp='$str_date' 
					agent_name='$agent_name' timezone_offset='0'>\n";
					
		print FD "<module>\n";
		print FD "<name><![CDATA[Bytes send]]></name>\n";
		print FD "<description><![CDATA[Amount of bytes send]]></description>\n";
		print FD "<type>generic_data</type>\n";
		print FD "<data><![CDATA[".$net_stats{$ip}->{SEND}."]]></data>\n";
		print FD "</module>\n";
		
		print FD "<module>\n";
		print FD "<name><![CDATA[Bytes recv]]></name>\n";
		print FD "<description><![CDATA[Amount of bytes received]]></description>\n";
		print FD "<type>generic_data</type>\n";
		print FD "<data><![CDATA[".$net_stats{$ip}->{RECV}."]]></data>\n";
		print FD "</module>\n";	
		
		print FD "<module>\n";
		print FD "<name><![CDATA[Requests]]></name>\n";
		print FD "<description><![CDATA[Number of request]]></description>\n";
		print FD "<type>generic_data</type>\n";
		print FD "<data><![CDATA[".$net_stats{$ip}->{REQ}."]]></data>\n";
		print FD "</module>\n";
		
		print FD "</agent_data>\n";			
		
		close (FD);
		
		
		#Calculate global stats
		$total_recv = $total_recv + $net_stats{$ip}->{SEND};
		$total_send = $total_send + $net_stats{$ip}->{RECV};
		$total_request  = $total_request + $net_stats{$ip}->{REQ};
	}
	
	#Generate global proxy net stats
	$time = time();
	
	$time =~ s/\..+//; 
	
	@date = localtime($time);
	
	my $global_name = $cfg->{MONITORING_GLOBAL_NAME};
		
	$str_date = strftime("%Y/%m/%d %H:%M:%S", @date);
	open(FD, ">", "pandora_data/".$global_name."_".$time.".data");
		
	print FD "<?xml version='1.0' encoding='ISO-8859-1'?>\n";
	print FD "<agent_data os_name='Other' os_version='1' group='$agent_group'
				interval='300' version='1' timestamp='$str_date' 
				agent_name='$global_name' timezone_offset='0'>\n";
				
	print FD "<module>\n";
	print FD "<name><![CDATA[Bytes send]]></name>\n";
	print FD "<description><![CDATA[Amount of bytes send for all ips]]></description>\n";
	print FD "<type>generic_data</type>\n";
	print FD "<data><![CDATA[".$total_send."]]></data>\n";
	print FD "</module>\n";
	
	print FD "<module>\n";
	print FD "<name><![CDATA[Bytes recv]]></name>\n";
	print FD "<description><![CDATA[Amount of bytes received for all ips]]></description>\n";
	print FD "<type>generic_data</type>\n";
	print FD "<data><![CDATA[".$total_recv."]]></data>\n";
	print FD "</module>\n";	
	
	print FD "<module>\n";
	print FD "<name><![CDATA[Requests]]></name>\n";
	print FD "<description><![CDATA[Number of request for all ips]]></description>\n";
	print FD "<type>generic_data</type>\n";
	print FD "<data><![CDATA[".$total_request."]]></data>\n";
	print FD "</module>\n";
	
	print FD "</agent_data>\n";
	
	close (FD);	
	
	#Reset array
	foreach my $ip (keys %net_stats){
		$net_stats{$ip}->{SEND} = 0;
		$net_stats{$ip}->{RECV} = 0;
		$net_stats{$ip}->{REQ} = 0;
	}		
	
	close (FD);
	
	### RELEASE for write ###
	$sem->up();				
}

sub monitoring {
	
	# Set up signal handler
	$SIG{TERM}=\&thread_exit;	
	
	print "Monitoring enabled\n";
	$LL>=1 and logline ("Monitoring enabled");	
	while (1) {
		dump_net_stats();
		sleep($cfg->{MONITORING_INTERVAL});
	}
}

#####
## these are functions for the client serving thread
#####
sub c_thread { # clientconnect [server_fileno]
	# in this thread, we have the following global variables:
	# $alrm
	# $c_fd, $c_fn
	# $t_fd, $t_fn, $t_ident, $t_inbuf, $t_seq, $t_incount, $t_outcount
	# ggf. $u_fd, $u_fn
	# $exitflag
	# $copts - holds the current connection options
	# $td, $te, $symkey - for encryption
	# $ip - holds the currently connected IP
	
	my $s_fn=shift;
	my $mode = defined($s_fn)?1:0;
	my ($errmsg, $errresp, $user, $pass, $method, $reason)=("","","","",0,"");

	# Set up signal handler
	$SIG{TERM}=\&thread_exit;
	
	$t_type{threads->tid}=$mode?"additional client worker":"permanent client worker";
	
	while (1) {
		if (!$mode) {
			setstatus ("Idle");
			$waitqueue->enqueue("-");
			$s_fn=$conqueue->dequeue;
			$waitqueue->dequeue;
		}
		$countqueue->enqueue("-");

	    # accept the incoming connection
		$c_fd="C".threads->tid;
		accept(CLIENT,$server_sockets{$s_fn}->{fd});
		select((select(CLIENT), $|=1)[$[]); # autoflush
		$ip = getpeername(CLIENT);
		my ($port, $iaddr) = sockaddr_in($ip);
		$ip = inet_ntoa($iaddr);
		open ($c_fd,"+<&CLIENT");
		close (CLIENT);
		$c_fn=fileno($c_fd);
		
		# signal our main process, that the connection is accepted and he can stop waiting
		$syncqueue->enqueue("x");
		if (id_isipbanned($ip)) {next;}

		#  this is a normal connection
		if (!checkip($iaddr,$cfg->{SEC_IP})) {
			$LL>=1 and logline ("$c_fd: Unathorized access to Proxy client from $ip");
			next;}
			
		# get the remote server and port to connect to
		($dad, $dpo, $errmsg, $errresp, $user, $pass, $method, $url_requested, $ctype, $ip_fordward)=c_getclientinfo($server_sockets{$s_fn}->{rname},$server_sockets{$s_fn}->{rport}, $ip);
		
		if (defined($ip_fordward)) {
			$ip = $ip_fordward;
		}
		
		my $msg_client = $errmsg;
		
		#Check if dad is defined.It occurs when a web browser is closed
		#before the web page was loaded, for example.
		if (!defined($dad)) {
			next;
		}		
	
		# resolve the name if applicable
		if ($cfg->{DNS_RESOLUTION}) {
						
			my $i=inet_aton($dad);
			if (!$i && $cfg->{DNS_RESOLUTION} == 1) {
				$method |=32; $errmsg="no host $dad";}
			else {$dad=inet_ntoa($i);}
		}
		if ($method & 32) {
			$LL and logline ("$c_fd: SOCKS connect from ".($user?"$user@":"")."$ip failed: $errmsg");
			c_endclientinfo($method,"0.0.0.0",0,$errresp);
			next;
		}

		# try to open connection
		setstatus("Serving connection: $ip:$port ".(($method&4)?"UDP socket":(($method&8)?"BIND":"-> $dad:$dpo"))." (waiting for connection)");
		($errmsg, $reason, $bad , $bpo )=c_proxy_connect($method, $dad, $dpo, $user, $pass, $msg_client, $ip, $url_requested, $ctype, $ip_fordward);
		if ($errmsg) {
			$LL and logline ($method&4?
				("$c_fd: ".($user?"$user@":"")."$ip connected to SOCKS server but connect for UPD failed: $errmsg"):
				($method&8?
				("$c_fd: ".($user?"$user@":"")."$ip connected to SOCKS server but connect for BIND failed: $errmsg"):
				("$c_fd: ".($user?"$user@":"")."$ip connected to ".($method&3?"SOCKS":"")." server but connect to $dad:$dpo failed: $errmsg")));
			c_endclientinfo($method | 32,"0.0.0.0",0,"",$reason);
			next;
		}

		# set up encryption if applicable
		if ($copts & 2) {
			$td = Mcrypt->new(	algorithm => 'arcfour', mode => 'stream');
			$te = Mcrypt->new(	algorithm => 'arcfour', mode => 'stream');
			if (!$td || !$te) {
				$LL and logline (("$c_fd: ".($user?"$user@":"")."$ip connected to SOCKS server but Mcrypt object could not be initialized"));
				c_endclientinfo($method | 32,"0.0.0.0",0,"");
				next;
			}
			my $iv=substr($symkey,0,$td->{IV_SIZE});
			my $key=substr($symkey,$td->{IV_SIZE},$td->{KEY_SIZE});
			$td->init($key,$iv);
			$te->init($key,$iv);
		}
		
		# we now have a successful connection
		c_endclientinfo($method,$bad,$bpo,"");
	    $LL>=2 and logline($method&4?
	    	("$c_fd: New SOCKS established ".($user?"$user@":"")."$ip sending UDP packets"):
	    	($method&8?
	    	("$c_fd: New SOCKS established ".($user?"$user@":"")."$ip listening on bound socket"):
	    	("$c_fd: New ".($method&3?"SOCKS":"connection")." established ".($user?"$user@":"")."$ip -> $dad:$dpo")));
		$exitflag=$alrm=0;

		# main listening loop for the client
		$connection_ids{$t_ident}=1;
		while(!$exitflag) {
			setstatus("Serving connection: $ip:$port ".(($method&4)?"UDP socket":(($method&8)?"BIND":"-> $dad:$dpo"))."<br>Sent ".$t_outcount." bytes, received ".$t_incount." bytes");
			# set up the handles to select on
			my $rin=pack("B*", "0"x64);
			$u_fn and vec($rin,$u_fn,1)=1;
			$c_fn and vec($rin,$c_fn,1)=1;
			$t_fn and vec($rin,$t_fn,1)=1;
			$timediff=$alrm-time();
			while (select ($rout=$rin,undef,undef,$alrm==0?1:($timediff<0?0:($timediff>1?1:$timediff)))==-1) {}
	
			for $s_fileno (handles($rout)) {
				# Do we have data coming in from the proxy
				if (!$exitflag && $s_fileno==$t_fn) {
					c_proxy_datain ($ip, $method);
				}
				# Do we have data coming in from a client
				elsif (!$exitflag && $s_fileno) {
					c_clientdatain ($ip, $s_fileno);
				}
			}
			if (!$exitflag && $alrm!=0 && $alrm-time()<=0) {c_proxy_dataout();}
		}
		delete $connection_ids{$t_ident};

	} continue {
		if ($t_fd) {fileno($t_fd) and shutdown($t_fd,2);close ($t_fd);}
		if ($c_fd) {fileno($c_fd) and shutdown($c_fd,2);close ($c_fd);}
		$u_fd and close ($u_fd);
		$countqueue->dequeue;
		$mode and last;
	}
	delete($t_type{threads->tid});
	delete($t_status{threads->tid});
	threads->detach();
	thread_exit();
}

sub c_killclient {	# killclient [message] [loglevel]
	my $msg=shift;
	my $loglevel = shift || 2;
	$msg and $LL>=$loglevel and logline ("$c_fd: $msg");
	$LL>=2 and logline ("$c_fd: Sent ".$t_outcount." bytes, received ".$t_incount." bytes");
    fileno($c_fd) and shutdown($c_fd,2);
    close ($c_fd);
	fileno($t_fd) and shutdown($t_fd,2);
	close ($t_fd);
	$exitflag=1;
}

#Clean request deleting or replacing some headers
sub clean_request($) {
	my $buf = shift;
	
		# Clean request if uri only has host
	if ($buf =~ /Host: (.+)\r\n/) {
		my $host_addr = $1;

		if ($buf =~ /(GET) http:\/\/(.+) HTTP\/(.+)\r\n/ || 
			$buf =~ /(POST) http:\/\/(.+) HTTP\/(.+)\r\n/ ) {
			my $type = $1;
			my $uri = $2;
			my $version = $3;
						
			$uri =~ s/$host_addr//;
			
			#Replace uri with new cleaned one
			$buf =~ s/(GET|POST).+\r\n/$type $uri HTTP\/$version\r\n/g;
		} 
	}
	
	#Delete X-Forwarded-For header	
	$buf =~ s/X-Forwarded-For: (.+)\r\n//g;

	#Delete Via header
	$buf =~ s/Via: (.+)\r\n//g;
			
	return $buf;
}

sub c_clientdatain {	# c_clientdatain clientfileno
	my $ip_client = shift;
	my $fn=shift;
	my ($i,$buf)=(0,"");

	# the next part is the only way to throttle incoming data so we wont have to buffer an unlimited amount.
	# downside: this part will notch up CPU usage to 100% while sending outbund data - a small relieve is hopefully
	# the yield()
	if ($sendqueue->pending>=$cfg->{DATA_SEND_MAXSIMCONN}/2) {
		threads->yield();
		return ;
	}

	if ($fn == $c_fn) {
		$i=sysread($c_fd,$buf,$cfg->{DATA_SEND_THRESHHOLD});}
	else {
		$i=recv($u_fd,$buf,65536,0);
	}
	
	# Clean request to ensure headers are right	
	$buf = clean_request($buf);

	
	if (!$i) {
		# do we have a client disconnect?
		$LL>=4 and logline ("$c_fd: Client -> proxy disconnect start");
		{lock (%outqueue);$outqueue{$t_ident}.=($t_seq++).":c:disconnect\n";}
	    fileno($c_fd) and shutdown($c_fd,2);close ($c_fd);
	    fileno($u_fd) and shutdown($u_fd,2);close ($u_fd);
		$c_fn=$u_fn=0;
	} else {
		$LL>=4 and logline ("$c_fd: Got data from client: ".bin2txt($buf));
		# we need to pipe the data into the outgoing proxy queue
		# works as follows:
		# 0. compress if applicable
		# 1. we add the outgoing data to the outgoing queue
		# 2. if the outgoing queue is greater than the threshhold, we send the data right away
		# 3. we (re)schedule sending the outgoing queue after a delay - maybe within this delay we get new data in the outqueue
		if ($fn != $c_fn) {
			my ($p,$s)=sockaddr_in($i);
			if (($dad ne "0.0.0.0" && inet_aton($dad) ne $s) || ($dpo!=0 && $dpo!=$p)) {
				$LL and logline("Security warning: received unauthorized UDP packet from ".inet_ntoa($s).":$p, expected $dad:$dpo");
				return;}
			# preprocess our UDP package
			ord(substr($buf,3,1)) == 4 and return; # we dont support IPv6 .. drop packages silently
			ord(substr($buf,2,1)) != 0 and return; # we dont support fragmentation .. drop packages silently
			$i=length($buf)-7-(ord(substr($buf,3,1))==1?3:ord(substr($buf,4,1)));
		}
		$t_outcount+=$i;
		update_net_stats($ip_client, $i, "send");
		$LL>=9 and logline("$c_fd: -> ".bin2txt(substr($buf,-$i)));
		# zip and encrypt the contents if applicable
		$copts & 1 and $buf=compress($buf,9);
		$copts & 2 and $buf=$te->encrypt($buf);
		{lock (%outqueue);$outqueue{$t_ident}.=($t_seq++).":".encode_base64($buf, '')."\n";}
	}
	$t_seq %= $cfg->{DATA_SEQUENCE_WRAP};
	if (length(join("",values(%outqueue)))>$cfg->{DATA_SEND_THRESHHOLD}) {
		c_proxy_dataout();
	} else {
		$alrm=time()+$cfg->{DATA_SEND_DELAY}/1000;
	}
}

sub c_proxy_dataout {	# c_proxy_dataout
	my $sendout='';
	$alrm=0;
	{
		lock(%outqueue);
		scalar(%outqueue) or return;
		$LL>=4 and logline("$c_fd: c_proxy_dataout(): Sending outbound traffic");
		for (keys(%outqueue)) {
			$outqueue{$_} eq '' and next;
			$sendout.=">$_\n".$outqueue{$_};
		}
		%outqueue=();
	}
	$sendout and $sendqueue->enqueue($sendout);
}

sub c_proxy_datain {	# c_proxy_datain method
	my $ip_client = shift;
	my $method=shift;
	my ($buf,$rawbuf,$i);
	
	if (!sysread($t_fd,$buf,65536)) {
		# we lost a proxy connection - disconnect the corresponding client
		c_killclient ("Irregular proxy disconnect -> disconnecting client",1);
		return;
	}
		
	$LL>=9 and logline("$c_fd: c_proxy_datain : $buf");
	# we need to pipe the data into the client socket
	$t_inbuf.=$buf;
	while ($t_inbuf=~m/^([^\n]*)\n/s) {
		$1 or next;
		$buf=$1;
		if ($buf=~m/^l:(\d+ )?(.*)$/) {$LL>=$1 and logline ("$c_fd: Server said: $2");}
		elsif ($buf=~m/^b:([\d\.]+):(\d+)$/) { # bind: we have a connect
			c_endclientinfo($method, $1, $2, "");
		}
		elsif ($buf=~m/^c:disconnect (.*)$/) {c_killclient("Disconnect $1"); return;}
		elsif ($buf=~m/^\s*<.*>\s*$/) {next;}
		else {
			# we're wrapping the decoding into an eval so we can handle protocol errors gracefully
			eval{$rawbuf=decode_base64($buf)};
			if ($rawbuf) {
				# decrypt and unzip the contents if applicable
				$copts & 2 and $rawbuf=$td->decrypt($rawbuf);
				$copts & 1 and $rawbuf=uncompress($rawbuf);
				if ($method & 4) { # udp package
					fileno($u_fd) and send($u_fd,$rawbuf,0,sockaddr_in($dpo,inet_aton($dad)));
					substr($rawbuf,0,10)="";
				} else {
					mysyswrite($c_fd,$rawbuf);}
					
				update_net_stats($ip_client, length($rawbuf), "recv");
				$t_incount+=length($rawbuf);
				$LL>=3 and logline ("$c_fd: <- ".bin2txt($rawbuf));
			} else {
				$LL>=1 and logline ("$c_fd: Protocol ERROR: $buf");
			}
		}
	} continue {$t_inbuf=~s/^([^\n]*)\n//s;}
}

sub c_proxy_connect {	# usage: c_proxy_connect method server port user pass
	#initialize datain connection
	my ($method, $sn, $sp, $user, $pass, $msg_client, $client_ip, $url_requested, $ctype)=@_;
	$u_fd="U".threads->tid;
	$t_fd="T".threads->tid;

	# open our UDP port if applicable
	if ($method & 4) {
		$sn = (sockaddr_in(getsockname($c_fd)))[1];
		socket($u_fd, PF_INET, SOCK_DGRAM, getprotobyname('udp')) or return "UDP socket: $!";
		bind($u_fd, sockaddr_in(0, $sn)) or return "UDP bind: $!";
		select((select($u_fd), $|=1)[$[]); # autoflush
		$sp = (sockaddr_in(getsockname($u_fd)))[0];
		$sn=inet_ntoa($sn);
		$u_fn=fileno($u_fd);
	}

	# connect the main connection
	my $ident="";
	socket($t_fd, PF_INET, SOCK_STREAM, getprotobyname('tcp'))  || return "socket: $!";
	connect($t_fd, $tpaddr) || return "connect(".($cfg->{PROXY_SERVER}?$cfg->{PROXY_SERVER}:$cfg->{SERVER}).":".($cfg->{PROXY_SERVER}?$cfg->{PROXY_PORT}:$cfg->{PORT})."): $!";
	select((select($t_fd), $|=1)[$[]); # autoflush

	# copts: connection options:
	# copts & 1: zlib compressed traffic
	# copts & 2: encrypted traffic
	# copts & 4: udp socket
	# copts & 8: bind server port
	
	$copts=0;
	$cfg->{ENABLE_ZLIB} and $copts |= 1;
	$cfg->{ENCRYPTION} and $copts |=2;
	$copts |= $method & 12;	
	
	#Get satellite proxy
	my ($satellite_proxy, $denied) = get_satellite_proxy($sat_proxies, $client_ip, $url_requested);
		
	#Log request
	log_request ($cfg, $client_ip, $url_requested, $satellite_proxy, $denied);
	
	#If denied was defined print response and close connection
	if (defined($denied)) {
		$msg = denied_message($satellite_proxy);
		my $buff;
		sysread($c_fd,$buff,$cfg->{DATA_SEND_THRESHHOLD});
		mysyswrite($c_fd,$msg);
		close($c_fd);
		thread_exit();
	}	

	my $req= "GET ".$satellite_proxy->{URI}.
		"?a=c&sw=$cfg->{DATA_SEQUENCE_WRAP}&ctype=$ctype&s=".tourl($sn)."&p=$sp&o=$copts".
		($cfg->{ENCRYPTION}?"&pk=".tourl($pubkey):"")." HTTP/1.0\r\n";
	$req.="Host: ".$satellite_proxy->{SERVER}."\r\n";
	if ($satellite_proxy->{AUTH_TYPE} eq "basic") {
		if ($satellite_proxy->{AUTH_PASSTHROUGH} && defined($user) && $user) {
			$req.="Authorization: Basic ".encode_base64($user.":".$pass,'')."\r\n";}
		elsif ($satellite_proxy->{AUTH_USER}) {
			$req.="Authorization: Basic ".encode_base64($satellite_proxy->{AUTH_USER}.":".$satellite_proxy->{AUTH_PASS},'')."\r\n";}
	}
	if ($cfg->{PROXY_SERVER} && $cfg->{PROXY_AUTH_TYPE} eq "basic") {
		if ($cfg->{PROXY_AUTH_PASSTHROUGH} && defined($user) && $user) {
			$req.="Proxy-Authorization: Basic ".encode_base64($user.":".$pass,'')."\r\n";}
		elsif ($cfg->{PROXY_AUTH_USER}) {
			$req.="Proxy-Authorization: Basic ".encode_base64($cfg->{PROXY_AUTH_USER}.":".$cfg->{PROXY_AUTH_PASS},'')."\r\n";}
	}
	$req.="\r\n";
	$LL>=4 and logline("$c_fd: Request to connect to proxy: $req");
	mysyswrite($t_fd,$req);

	# get the headers and the connect message
	my ($buf,$in,$i);
	while (1) {
		$in="";
		while (1) {
			mysysread($t_fd,$buf,1) or return "Server closed connection before complete headers were sent";
			$buf eq "\n" and last;
			$in.=$buf;
		}
		$LL>=4 and logline("$c_fd: Response: $in");
		$in=~s/[\r\n]//g;
		if ($in=~m|^HTTP/[\d\.]+ (\d+)(.*)$| && $1 ne "200") {
			return "HTTP Error: $1$2";
		}
		if ($in=~m|^c:(.*)$|) {
			my $p=getparams($1);
			$p->{s} eq "ER" and return "Proxy Error: ".$p->{msg};
			$ident=$p->{i};
			if (!($method & 4)) {$sn=$p->{sn};$sp=$p->{sp};}
			# check if we're falling back to unencrypted/uncompressed and if this is acceptable
			$copts & 2 and !($p->{o} & 2) and !$cfg->{ENCRYPTION_FALLBACKOK} and return "Proxy server does not support encryption";
			$copts & 2 and !($p->{o} & 2) and $LL>=2 and logline("$c_fd: WARNING: Proxy server does not support encryption - data will be transmitted unencrypted");
			$copts & 1 and !($p->{o} & 1) and $LL>=2 and logline("$c_fd: WARNING: Proxy server does not support compression - data will be transmitted uncompressed");
			$copts=$p->{o};
			$copts & 2 and $symkey=ssl_decrypt(decode_base64($p->{k}),$rsa);
			last;
		}
	}
	
	# check if connect method was detected
	if ($ctype eq "CONNECT") {
		# send OK msg to client
		$LL>=3 and logline ("Send response to CONNECT command");		
		my $resp_buff =  "HTTP/1.0 200 Connection established\r\n\r\n";
		mysyswrite($c_fd,$resp_buff);
	}	
	
	# this is where we initialize all the proxy connected variables
	$t_fn=fileno($t_fd);
	$t_ident=$ident;
	$t_inbuf="";
	$t_seq=0;
	$t_incount=0;
	$t_outcount=0;
	("", undef, $sn, $sp);
}

# does the SOCKS v4 or v5 handshake before the proxy is connected
sub c_getclientinfo {	# usage: get_getclientinfo servername, serverport
	my ($svrn, $svrp) = @_;
	my ($b,$sn,$sp,$us,$pa,$method,$errresp,$msg, @a)=("","",0,"","",0,"","protocol error",());
	# method return:
	# m & 1: socks4
	# m & 2: socks5
	# m & 4: udp
	# m & 8: bind
	# m & 16: address type string
	# m & 32: error occurred

	# we have a portmapping request
	if ($svrp ne "S") {


		my $buff;
		my $error = "";
		
		recv ($c_fd, $buff, $cfg->{DATA_SEND_THRESHHOLD}, MSG_PEEK);
		
		my $method = "";
		my $hots = "";
		my $port = "";
		my $socket_method = 16;
		my $url_requested = "";
		my $ctype = "NORMAL";
		my $ip_fordward = undef;
		# Get hostname and port
		
		if ($buff =~ /(CONNECT) (.+):(.+) HTTP.+\r\n/) {
			$LL>=3 and logline("HTTPS request detected");
			# It is a HTTPS connection
			$host = $2;
			$port = $3;
			$ctype = "CONNECT";
			#Collect url requested for connect method
			$url_requested = $host.":".$port;
			
			recv($c_fd,$buff,$cfg->{DATA_SEND_THRESHHOLD}, 0);
			
		} elsif ($buff =~ /Host: (.+)\r\n/) {
			my $aux = $1;
						
			#Collect url requested for post and get methods
			if ($buff =~ /GET (.+) HTTP.+\r\n/) {
				$url_requested = $1;
			} elsif ($buff =~ /POST (.+) HTTP.+\r\n/) {
				$url_requested = $1;
			}
		
			$LL>=3 and logline("HTTP request detected");
			# Check if port comes with host
			if ($aux =~ /(.+):(.+)/) {
				$host = $1;
				$port = $2;
			} else {
				$host = $aux;
				$port = 80;
			}
		}	
		
		#Check if IP was fordwarded
		if ($buff =~ /X-Forwarded-For: (.+)\r\n/) {
			$ip_fordward = $1;
		}
				
		$LL>=4 and logline("$c_fd: Client trying to connect to server");
		return ($host,$port,$error,"","","",16, $url_requested, $ctype, $ip_fordward);
	}

	# we have a socks request
	while (1) {
		mysysread($c_fd,$b,1) or last;
		if ($b eq chr(4)) {
			$LL>=4 and logline("$c_fd: Client trying to connect to SOCKS4 server");
			# SOCKS 4
			$method |=1;
			mysysread($c_fd,$b,7) or last;
			@a=unpack("C*",$b);
			if ($a[0] != 1) {
				#$msg="client bind() - not yet supported";
				$method |= 8;}
			$sp=$a[1]*256+$a[2];

			# get and validate the username if applicable
			while (mysysread($c_fd,$b,1) and $b ne "\000") {$us.=$b;}
			$b=checkuser($cfg->{SOCKS_AUTH},$us,"",$cfg->{SOCKS_USER});
			$LL>=4 and logline("$c_fd: SOCKS4 username: $us");
			if ($b) {
				id_addaccess($ip);
				$errresp=pack("C*",0x00,0x5b,0,0,0,0,0,0);
				$msg=$b;
			} else {
				id_delaccess($ip);}

			# do we have SOCKS 4a?
			if ($a[3]==0) {
				$method |= 16;
				$sn="";
				while (mysysread($c_fd,$b,1) and $b ne "\000") {$sn.=$b;}
			} else {
				$sn=inet_ntoa(pack("CCCC",$a[3],$a[4],$a[5],$a[6]));
			}
		} elsif ($b eq chr(5)) {
			$LL>=4 and logline("$c_fd: Client trying to connect to SOCKS5 server");
			# get the first package with the list of supported authentication methods
			$method |=2;
			mysysread($c_fd,$b,1) or last;
			mysysread($c_fd,$b,ord($b)) or last;
			my $autmet=",".join(",",unpack("C*",$b)).",";
			if ($autmet=~m/,2,/) { # user pass authentication is always preferred
				mysyswrite($c_fd,pack("C*",5,2));
				# get the user name and password
				mysysread($c_fd,$b,1) or last;
				mysysread($c_fd,$b,1) or last;
				if (ord($b)) {mysysread($c_fd,$us,ord($b)) or last;}
				mysysread($c_fd,$b,1) or last;
				if (ord($b)) {mysysread($c_fd,$pa,ord($b)) or last;}
				$b=checkuser($cfg->{SOCKS_AUTH},$us,$pa,$cfg->{SOCKS_USER});
				if ($b) {
					id_addaccess($ip);
					$errresp=pack("C*",1,1);
					$msg=$b;
					last;
				}
				id_delaccess($ip);
				mysyswrite($c_fd,pack("C*",1,0));
			} elsif ($cfg->{SOCKS_AUTH}==0 && $autmet=~m/,0,/) { # no authentication?
				mysyswrite($c_fd,pack("C*",5,0));
			} else {	# unsupported authentication
				$errresp=pack("C*",5,255);
				$msg="authentication required or authentication method not supported";
				last;
			}
			# get the connect request
			mysysread($c_fd,$b,4) or last;
			@a=unpack("C*",$b);
			if ($a[1] == 2) { # client requests bind
				#$msg="client requested bind - not yet supported";
				$method |= 8;
			}
			if ($a[1] == 3) { # client requests udp
				$method |= 4;
			}
			if ($a[3] == 1) {
				mysysread($c_fd,$b,4) or last;
				$sn=inet_ntoa($b);
			} elsif ($a[3] == 3) {
				$method |= 16;
				mysysread($c_fd,$b,1) or last;
				mysysread($c_fd,$sn,ord($b)) or last;
			} else {
				mysysread($c_fd,$b,16) or last;
				$msg="IPv6 addresses not supported";
			}
			mysysread($c_fd,$b,2) or last;
			@a=unpack("C*",$b);
			$sp=$a[0]*256+$a[1];

		} else {last;}
		$msg eq "protocol error" and $msg="";
		last;
	}
	# next line is for udp clients that dont know their own address
	if ($sn eq "0.0.0.0" or $sn eq "127.0.0.1") {$sn=inet_ntoa((sockaddr_in(getpeername($c_fd)))[1]);}
	($sn,$sp,$msg, $errresp, $us, $pa, $method|($msg?32:0));
}

# does the SOCKS v4 or v5 handshake after the proxy is connected
sub c_endclientinfo {	#usage: c_endclientinfo method, servername, port, response, [byte]
	my ($method, $sn,$sp, $buf, $errbyte)=@_;
	$sn or $sn="0.0.0.0";$sp or $sp=0;	
	$method & 3 or return; # no socks
	if (!$buf && $method & 1) { # socks4
		$buf=pack("C*", 0x00, defined($errbyte)?$errbyte:($method&32?0x5b:0x5a), int($sp/256), $sp%256).inet_aton($sn);
	} elsif (!$buf && $method & 2) {# socks5
		$buf=pack("C*", 0x05, defined($errbyte)?$errbyte:($method&32?1:0), 0x00, 0x01).inet_aton($sn).pack("C*", int($sp/256), $sp%256);
	}
	mysyswrite($c_fd, $buf);
}

#####
## this is the outbound data sending worker thread
#####
sub o_thread {	# o_thread
	my $ot_fd="OT".threads->tid;
	my ($buf, $in, $data, $lasterr, $req, $retry, @a, %h, %resp, $i, $ta);

	# Set up signal handler
	$SIG{TERM}=\&thread_exit;

	$t_type{threads->tid}="outbound traffic worker";
	OUTER: while (1) {
		setstatus ("Idle");
		$data=$sendqueue->dequeue;
		# first of all, we need to split our data into a hash
		# (so we can selectively remove successfully sent packages when retrying)
		%h=();
		@a=split(/\n/,$data);
		$buf="";
		for(@a) {
			if (m/^>(.*)$/) {$buf=$1;next;}
			$buf eq "" and next;
			$h{$buf}.="\n".$_;
		}
		my $psize=int(length(join("",values(%h)))*0.75);
		$retry=1;
		while ($retry<=$cfg->{DATA_SEND_RETRYCOUNT}) {
			setstatus ("Sending outbound traffic package (~$psize byte) - try $retry/$cfg->{DATA_SEND_RETRYCOUNT}");
			# now, we're piecing together our request to be sent
			$data="";
			for (keys(%h)) {($connection_ids{$_} and $data.=">".$_.$h{$_}."\n") or delete $h{$_} ;}
			keys(%h)==0 and last;
			$req= "POST ".($cfg->{PROXY_SERVER}?("http://$cfg->{SERVER}:$cfg->{PORT}"):"").$cfg->{URL}."?a=s HTTP/1.1\r\n";
			$req.="Host: $cfg->{SERVER}\r\n";
			$cfg->{AUTH_TYPE} eq "basic" and $cfg->{AUTH_USER} and
				$req.="Authorization: Basic ".encode_base64($cfg->{AUTH_USER}.":".$cfg->{AUTH_PASS},'')."\r\n";
			$cfg->{PROXY_SERVER} and $cfg->{PROXY_AUTH_USER} and
				$cfg->{PROXY_AUTH_TYPE} eq "basic" and 
				$req.="Proxy-Authorization: Basic ".encode_base64($cfg->{PROXY_AUTH_USER}.":".$cfg->{PROXY_AUTH_PASS},'')."\r\n";
			$req.="Content-Type: application/x-www-form-urlencoded\r\n";
			$req.=($cfg->{PROXY_SERVER}?("Proxy-"):"")."Connection: Keep-Alive\r\n";
			$buf="d=".tourl($data);
			$req.="Content-Length: ".length($buf)."\r\n";
			$req.="\r\n$buf";
			
			# connect and send the request
			if ($ta && time()>$ta) {fileno($ot_fd) and shutdown($ot_fd,2);close ($ot_fd);}
			if (!fileno($ot_fd)) {
				if (!socket($ot_fd, PF_INET, SOCK_STREAM, getprotobyname('tcp'))) {
					$lasterr="socket() failed: $!";
					next;}
				setsockopt($ot_fd, SOL_SOCKET, SO_SNDTIMEO, pack('LL', $cfg->{OUTSOCKET_TIMEOUT}, 0) );
				setsockopt($ot_fd, SOL_SOCKET, SO_RCVTIMEO, pack('LL', $cfg->{OUTSOCKET_TIMEOUT}, 0) );

				if (!connect($ot_fd, $tpaddr)) {
					$lasterr="connect() failed: $!";
					next;}
				select((select($ot_fd), $|=1)[$[]); # autoflush
			}

			$LL>=4 and logline("$ot_fd: Request to send data: $req");
			if (!mysyswrite($ot_fd,$req)) {
				$lasterr="Could not write to socket";next;}
			$LL>=4 and logline("$ot_fd: Sent request, waiting for response");

			# get the response
			%resp=getHTTPresponse($ot_fd,1);

			# should we calculate a keepalive timeout?
			if (defined($resp{"h_keep-alive"}) && $resp{"h_keep-alive"}=~m/timeout=(\d+)/i) {
				$ta=time()+$1-2;	# we're subtracting 2 seconds just to be safe
			} else {$ta=0;}

			if (defined($resp{error})) {$lasterr="HTTP Error: $resp{error}";next;}
			for (split(/\n/,$resp{body})) {
				s/[\r\n]//g;
				if (m/^(.+?) ER (.*)/) {
					my ($i1,$i2)=($1,$2);
					if ($h{$i1}=~m/c:disconnect/) {delete($h{$i1});}
					else {$lasterr="Server said: $i2";}}
				elsif (m/^(.+?) OK/) {delete($h{$1});}
				elsif (m/^l:(\d+ )?(.*)$/) {$LL>=$1 and logline ("$ot_fd: Server said: $2");}
			}
		} continue {
			my $i=$cfg->{PROXY_SERVER}?$resp{"h_proxy-connection"}:$resp{"h_connection"};
			if (!defined($i) || $i!~m/^keep-alive$/i) {
				fileno($ot_fd) and shutdown($ot_fd,2);close ($ot_fd);
			}
			keys(%h)==0 and last;
			$LL>=3 and logline("$ot_fd: NOTICE Outbound proxy error on attempt $retry: $lasterr");
			$retry++;
		}
		if (keys(%h)>0) {
			$LL and logline("$ot_fd: ERROR Outbound proxy error on final attempt: $lasterr!");
		}
	}
	fileno($ot_fd) and shutdown($ot_fd,2);
	close ($ot_fd);
}

sub connection_restart {
	$restartq->enqueue("Caught SIG$_[0] - Restarting ...");
}

sub connection_exit {
	connection_cleanup (($_[0]?"Caught SIG$_[0] - ":"")."Shutting down");
	exit (0);
}

sub connection_cleanup {
	my ($i,$fd);
	defined ($_[0]) and logline ($_[0],$LL,1);
	# clean up the logger thread
	if ($LL) {
		$logqueue->enqueue("x");
		$log_t->join;
	}
	# clean up all other threads
	foreach $i (threads->list()) {$i->kill("TERM");}
	foreach $i (threads->list()) {defined ($sendqueue) and $sendqueue->enqueue("x");$conqueue->enqueue("x");}
	# shut down all server sockets
	if (%server_sockets) {
		for $i (keys(%server_sockets)) {
			$fd=$server_sockets{$i}->{fd};
			fileno($fd) and shutdown($fd,2);close($fd);
		}
	}
	fileno(SERVER) and shutdown(SERVER,2);close (SERVER);
	foreach $i (threads->list()) {$i->join();}
}
