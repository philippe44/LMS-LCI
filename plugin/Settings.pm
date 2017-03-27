package Plugins::LCI::Settings;
use base qw(Slim::Web::Settings);

use strict;

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log = logger('plugin.LCI');

sub name {
	return 'PLUGIN_LCI';
}

sub page {
	return 'plugins/LCI/settings/basic.html';
}

sub prefs {
	return (preferences('plugin.LCI'), qw(no_cache icons));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;
	
	$callback->($client, $params, $class->SUPER::handler($client, $params), @args);
}

	
1;
