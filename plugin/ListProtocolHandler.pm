package Plugins::LCI::ListProtocolHandler;

use strict;

use Slim::Utils::Log;

use Plugins::LCI::API;
use Plugins::LCI::Plugin;
use Data::Dumper;

Slim::Player::ProtocolHandlers->registerHandler('lciplaylist', __PACKAGE__);

my $log = logger('plugin.LCI');

sub overridePlayback {
	my ( $class, $client, $url ) = @_;
		
	if ( $url !~ m|(?:lciplaylist)://link=(\S*)|i ) {
		return undef;
	}
	
	my $link = $1;
	
	$log->debug("playlist override $link");
	
	Plugins::LCI::Plugin->searchEpisodes( sub {
			my $result = shift;
			
			createPlaylist($client, $result); 
			
		}, undef, { link => $link } );
			
	return 1;
}

sub createPlaylist {
	my ( $client, $items ) = @_;
	my @tracks;
		
	for my $item (@{$items}) {
		push @tracks, Slim::Schema->updateOrCreate( {
				'url'        => $item->{play} });
	}	
	
	$client->execute([ 'playlist', 'clear' ]);
	$client->execute([ 'playlist', 'addtracks', 'listRef', \@tracks ]);
	$client->execute([ 'play' ]);
}

sub canDirectStream {
	return 1;
}

sub contentType {
	return 'LCI';
}

sub isRemote { 1 }


1;
