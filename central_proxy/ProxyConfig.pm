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

package main;

sub readconfig { # readconfig <filename>
    my $fname=shift;
    my $tmp;
    my %cfg=();
    open (FD,"<$fname") or die ("$fname: $!");
    while (<FD>) {
        chomp;
        if (m/^\s*$/) {next;}
        if (m/^#\s*(.*)$/) {next;}
        if (m/^\s*(\w+?)\s*=\s*("|)(.*?)("|)\s*$/) {
            $tmp=$1;
            $cfg{$tmp}.=((!defined($cfg{$tmp}) || $cfg{$tmp} eq "")?"":"\n").(defined($3)?$3:"");
	}	}
    close FD;
    return \%cfg;
}


sub closeconf {
	
};
1;
