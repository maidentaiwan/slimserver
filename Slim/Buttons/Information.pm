package Slim::Buttons::Information;

#	$Id$
#
#	Author: Kevin Walsh <kevin@cursor.biz>
#	Copyright (c) 2003-2007 Logitech, Cursor Software Limited.
#	All rights reserved.
#
#	This program is free software; you can redistribute it and/or modify
#	it under the terms of the GNU General Public License as published by
#	the Free Software Foundation; either version 2 of the License, or
#	(at your option) any later version.
#
#	This program is distributed in the hope that it will be useful,
#	but WITHOUT ANY WARRANTY; without even the implied warranty of
#	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#	GNU General Public License for more details.
#
#	You should have received a copy of the GNU General Public License
#	along with this program; if not, write to the Free Software
#	Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
#	02111-1307 USA
#

=head1 NAME

Slim::Buttons::Information

=head1 DESCRIPTION

L<Slim::Buttons::Information> is a SqueezeCenter module to display player library
and module information.

Displays various bits of information relating to the SqueezeCenter,
the current player, the music library and the installed plug-in
modules.

Scroll through the information items using the up/down buttons.
If you see a "->" symbol then you may press RIGHT to move into
a sub-menu.  Press LEFT to move out of a sub-menu.

=cut

use strict;

use File::Spec::Functions qw(catdir);

use Slim::Buttons::Common;
use Slim::Music::Info;
use Slim::Utils::Misc;
use Slim::Utils::Network;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

# since we just jump into INPUT.List, we don't need any functions of our own
our %functions = ();

# array for internal values of the player submenu which can be added to
our @player_list = ('PLAYER_NAME','PLAYER_MODEL','FIRMWARE','PLAYER_IP','PLAYER_PORT','PLAYER_MAC');

# array of value functions for player submenu which can be added to
our @player_func = (
	sub { shift->name },
	sub { return playerModel(shift) },
	sub { shift->revision },
	sub { shift->ip },
	sub { shift->port },
	sub { uc(shift->macaddress) },
);

# hash of current locations in the menu structure
# This is keyed by the $client object, then the second level
# is keyed by the menu.  When entering any menu, the valueRef parameter
# passed to INPUT.List refers back to here.
our %current = ();

our %menuParams = ();

sub init {
	Slim::Buttons::Common::addMode('information', getFunctions(), \&setMode);

	Slim::Buttons::Home::addSubMenu('SETTINGS', 'INFORMATION', {
		'useMode'   => 'information',
		'condition' => sub { 1 },
	});

	# hash of parameters for the various menus, these will be passed to INPUT.List
	# Some of the parameters aren't used by INPUT.List, but it is handy to let them be
	# stored in the mode stack.
	%menuParams = (

		'main' => {

			'header' => 'INFORMATION',
			'stringHeader' => 1,
			'headerAddCount' => 1,
			'externRef' => sub { return $_[0]->string('INFORMATION_MENU_' . uc($_[1])) },
			'externRefArgs' => 'CV',
			'listRef' => ['library','player','server','module'],
			'overlayRef' => sub { return (undef,shift->symbols('rightarrow')) },
			'overlayRefArgs' => 'C',
			'fonts' => { 'graphic-160x32' => 'light_n' },
			'callback' => \&mainExitHandler,
		},

		catdir('main','library') => {

			'header' => 'INFORMATION_MENU_LIBRARY',
			'stringHeader' => 1,
			'headerAddCount' => 1,
			'listRef' => ['TIME','ALBUMS','TRACKS','ARTISTS','GENRES'],
			'externRef' => \&infoDisplay,
			'externRefArgs' => 'CV',
			'overlayRef' => \&infoDisplayOverlay,
			'overlayRefArgs' => 'CV',
			'formatRef' => [
				\&timeFormat,
				\&Slim::Utils::Misc::delimitThousands,
				\&Slim::Utils::Misc::delimitThousands,
				\&Slim::Utils::Misc::delimitThousands,
				\&Slim::Utils::Misc::delimitThousands,
			],
			'fonts' => { 'graphic-160x32' => 'light_n' },

			'valueFunctRef' => [
				sub { return Slim::Schema->totalTime },
				sub { return Slim::Schema->count('Album') },
				sub { return Slim::Schema->count('Track', { 'me.audio' => 1 }) },
				sub { return Slim::Schema->rs('Contributor')->browse->count },
				sub { return Slim::Schema->count('Genre') },
			],

			'menuName' => 'library'
		},

		catdir('main','player') => {

			'header' => 'INFORMATION_MENU_PLAYER',
			'stringHeader' => 1,
			'headerAddCount' => 1,
			'listRef' => [],       # this is replaced in mainExitHandler
			'externRef' => \&infoDisplay,
			'externRefArgs' => 'CV',
			'overlayRef' => \&infoDisplayOverlay,
			'overlayRefArgs' => 'CV',
			'fonts' => { 'graphic-160x32' => 'light_n' },
			'valueFunctRef' => [], # this is replaced in mainExitHandler
			'menuName' => 'player'
		},

		catdir('main','server') => {

			'header' => 'INFORMATION_MENU_SERVER',
			'stringHeader' => 1,
			'headerAddCount' => 1,
			'listRef' => [qw(VERSION SERVER_PORT SERVER_HTTP HOSTNAME HOSTIP CLIENTS DIAGSTRING)],
			'externRef' => \&infoDisplay,
			'externRefArgs' => 'CV',
			'overlayRef' => \&infoDisplayOverlay,
			'overlayRefArgs' => 'CV',
			'fonts' => { 'graphic-160x32' => 'light_n' },
			'formatRef' => [
				undef,
				undef,
				undef,
				undef,
				undef,
				\&Slim::Utils::Misc::delimitThousands,
				'left',
			],

			'valueFunctRef' => [
				sub { $::VERSION },
				sub { 3483 },
				sub { preferences('server')->get('httpport') },
				\&Slim::Utils::Network::hostName,
				\&Slim::Utils::Network::serverAddr,
				\&Slim::Player::Client::clientCount,
				\&Slim::Utils::Misc::settingsDiagString,
			],

			'menuName' => 'server'
		},

		catdir('main','module') => {

			'header' => 'INFORMATION_MENU_MODULE',
			'stringHeader' => 1,
			'headerAddCount' => 1,
			'listRef' => \&moduleList,
			'externRef' => \&moduleDisplay,
			'externRefArgs' => 'CV',
			'fonts' => { 'graphic-160x32' => 'light_n' },
			'menuName' => 'module',
		}
	);
}

=head2 forgetClient ( $client )

Clean up global hash when a client is gone

=cut

sub forgetClient {
	my $client = shift;
	
	delete $current{ $client };
}

sub timeFormat {
	my $time = shift || 0;

	sprintf(
	    "%d:%02d:%02d",
	    ($time / 3600),
	    ($time / 60) % 60,
	    $time % 60,
	);
}

# function providing the second line of the display for the
# library, server, and player menus
sub infoDisplay {
	my ($client,$value) = @_;

	my $listIndex     = $client->modeParam('listIndex');
	my $formatRef     = $client->modeParam('formatRef');
	my $valueFunctRef = $client->modeParam('valueFunctRef');
	
	if (defined($formatRef) && defined($formatRef->[$listIndex]) && $formatRef->[$listIndex] eq 'left') {
		return $valueFunctRef->[$listIndex]->($client);
	}

	return $client->string('INFORMATION_' . uc($value));
}

# function providing the overlay portion of the display for the
# library, server, and player menus
sub infoDisplayOverlay {
	my ($client,$value) = @_;

	my $listIndex     = $client->modeParam('listIndex');
	my $formatRef     = $client->modeParam('formatRef');
	my $valueFunctRef = $client->modeParam('valueFunctRef');
	
	if (defined($formatRef) && defined($formatRef->[$listIndex])) {
		if ($formatRef->[$listIndex] eq 'left') {
			return ( undef, undef );
		} else {
			return ( undef, $formatRef->[$listIndex]->($valueFunctRef->[$listIndex]->($client)) );
		}
	} else {
		return ( undef, $valueFunctRef->[$listIndex]->($client) );
	}
}

# function defining the list of plugins to display
sub moduleList {
	my $plugins = Slim::Utils::PluginManager->allPlugins;

	my @modules;

	for my $key (keys %{$plugins}) {
		push @modules, $key if $plugins->{$key}->{'module'};
	}

	@modules = sort { string($plugins->{$a}->{'name'}) cmp string($plugins->{$b}->{'name'}) } @modules;

	return \@modules;
}

# function providing the second line of the display for the module menu
sub moduleDisplay {
	my $client = shift;
	my $key    = shift;

	my $plugin = Slim::Utils::PluginManager->dataForPlugin($key);

	my @info = $client->string($plugin->{'name'});

	my $version = $plugin->{'version'};

	if (!$version) {
		push @info, $client->string('INFORMATION_NO_VERSION');

	} else {
		$version =~ s/^\s+//;
		$version =~ s/\s+$//;

		push @info, $version;
	}

	if (Slim::Utils::PluginManager->isEnabled($key)) {
		push(@info, $client->string('ENABLED'));
	} else {
		push(@info, $client->string('INFORMATION_DISABLED'));
	}

	return join(' ' . $client->symbols('rightarrow') . ' ', @info);
}	

# callback function for the main menu, handles descending into the submenus
sub mainExitHandler {
	my ($client,$exittype) = @_;
	$exittype = uc($exittype);

	Slim::Utils::Timers::killTimers($client,\&updateClientStatus);
	if ($exittype eq 'LEFT') {

		Slim::Buttons::Common::popModeRight($client);

	} elsif ($exittype eq 'RIGHT') {

		my $nextmenu = catdir('main',$current{$client}{'main'});

		unless (exists $menuParams{$nextmenu}) {

			$client->bumpRight();
			return;
		}

		my %nextParams = %{$menuParams{$nextmenu}};
		if (ref $nextParams{'listRef'} eq 'CODE') {
			$nextParams{'listRef'} = $nextParams{'listRef'}->();
		}
		$current{$client}{$nextmenu} = $nextParams{'listRef'}[0] unless exists($current{$client}{$nextmenu}); 
		$nextParams{'valueRef'} = \$current{$client}{$nextmenu};

		if ($nextmenu eq catdir('main','player')) {
			my @nextList = @player_list;
			my @nextValueFunc = @player_func;
			if (defined($client->signalStrength())) {
				push @nextList, 'PLAYER_SIGNAL_STRENGTH';
				push @nextValueFunc, sub { return (shift->signalStrength() . '%') };
				Slim::Utils::Timers::setTimer($client,Time::HiRes::time() + 1,\&updateClientStatus);
			}
			if (defined($client->voltage())) {
				push @nextList, 'PLAYER_VOLTAGE';
				push @nextValueFunc, sub { return (shift->voltage() . 'VAC') };
				Slim::Utils::Timers::setTimer($client,Time::HiRes::time() + 1,\&updateClientStatus);
			}
			$nextParams{'listRef'} = \@nextList;
			$nextParams{'valueFunctRef'} = \@nextValueFunc;
		}

		Slim::Buttons::Common::pushModeLeft($client, "INPUT.List", \%nextParams);

	} else {

		return;
	}
}

# Standard button mode subs follow
sub setMode {
	my $client = shift;
	my $method = shift;

	if ($method eq 'pop') {
		Slim::Utils::Timers::killTimers($client, \&updateClientStatus);
		Slim::Buttons::Common::popMode($client);
		return;
	}

	$current{$client}{main} = 'library' unless exists($current{$client}{main});
	my %params = %{$menuParams{'main'}};
	$params{'valueRef'} = \$current{$client}{main};
	Slim::Buttons::Common::pushMode($client,'INPUT.List',\%params);
}

sub playerModel {
	my $client = shift;
	
	# special case for squeezebox v3 (can't use in $client->model due to some images
	# expecting "squeezebox" for v1-3)
	if ($client->model =~ /squeezebox/ && $client->macaddress =~ /^00:04:20((:\w\w){3})/) {
		my $id = $1;
		$id =~ s/://g;
		if ($id gt "060000") {
			return "Squeezebox v3";
		}
	}

	return $client->model;
}

sub updateClientStatus {
	my $client = shift;

	if (Slim::Buttons::Common::mode($client) eq 'INPUT.List' &&
	    Slim::Buttons::Common::param($client, 'parentMode') eq 'information' &&
	    (${Slim::Buttons::Common::param($client, 'valueRef')} eq 'PLAYER_SIGNAL_STRENGTH' ||
	     ${Slim::Buttons::Common::param($client, 'valueRef')} eq 'PLAYER_VOLTAGE')) {
		$client->requestStatus();
	
		$client->update();
	}

	Slim::Utils::Timers::setTimer($client,Time::HiRes::time() + 1,\&updateClientStatus);
}

sub getFunctions {
	\%functions;
}

=head1 SEE ALSO

L<Slim::Buttons::Common>

L<Slim::Music::Info>

L<Slim::Utils::Misc>

L<Slim::Utils::Network>

=cut

1;

__END__
