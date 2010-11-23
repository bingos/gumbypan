use strict;
use warnings;
use Email::Simple;
use POE qw(Component::IRC);
use POE::Component::IRC::Common qw( :ALL );
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::CTCP;
use POE::Component::IRC::Plugin::BotAddressed;
use POE::Component::Client::NNTP;
use POE::Component::CPANIDX;
use CPAN::DistnameInfo;
use Module::Util qw[is_valid_module_name];

use constant IDX => 'http://cpanidx.org/cpanidx/';

my $cmds = {
  'mod', 1,
  'dist' => 1,
  'auth', 1,
  'timestamp', 0,
  'dists', 1,
  'topten', 0,
};

my $nickname = 'GumbyPAN';
my $username = 'cpanbot';
my $password = '**********';
my $server = 'eu.freenode.net';
my $port = 6667;

my %channels = ( 
		'#perl' => '.*', 
		'#cpan' => '.*', 
		);

my $group = 'perl.cpan.uploads';

my $irc = POE::Component::IRC->spawn( debug => 0 );
my $idx = POE::Component::CPANIDX->spawn();
POE::Component::Client::NNTP->spawn ( 'NNTP-Client', { NNTPServer => 'nntp.perl.org', TimeOut => 60 } );

POE::Session->create(
    package_states => [ 
	'main' => [ qw(_start irc_001 irc_join irc_bot_addressed _nntp_connect _nntp_poll nntp_200 nntp_211 nntp_220 _default _idx) ], 
	'main' => { nntp_disconnected => '_disconnected', nntp_socketerr    => '_disconnected', },
    ],
    options => { trace => 0 },
);

$poe_kernel->run();
exit 0;

sub _start {
  my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
  $kernel->post ( 'NNTP-Client' => register => 'all' );
  $kernel->yield( '_nntp_connect' );
  $irc->yield( register => 'all' );
  $irc->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
  $irc->plugin_add( 'CTCP', POE::Component::IRC::Plugin::CTCP->new( eat => 0 ) );
  $irc->plugin_add( 'Addressed', POE::Component::IRC::Plugin::BotAddressed->new( eat => 0 ) );
  $irc->yield( connect => { Nick => $nickname, Server => $server, Port => $port, Username => $username, Password => $password } );
  return;
}

sub irc_001 {
  $irc->yield( 'join', $_ ) for keys %channels;
  return;
}

sub irc_join {
  my ($nickhost,$channel) = @_[ARG0,ARG1];
  return;
}

sub irc_bot_addressed {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  my $nick = ( split /!/, $_[ARG0] )[0];
  my $channel = $_[ARG1]->[0];
  my $what = $_[ARG2];
  return unless $what;

  my ($cmd,$search) = split /\s+/, $what;
  $cmd = lc $cmd;
  return unless defined $cmds->{ $cmd };
  my $arg = $cmds->{ $cmd };
  return if $arg and !$search;
  return if $cmd eq 'mod' and !is_valid_module_name($search);
  $idx->query_idx(
        event   => '_idx',
        cmd     => $cmd,
        search  => $search,
        url     => IDX,
        _data   => [ $channel, $nick, $cmd, $search ],
  );
  return;
}

sub _idx {
  my ($kernel,$res) = @_[KERNEL,ARG0];
  my ($channel,$nick,$cmd,$search) = @{ $res->{_data} };
  my $msg;
  if ( $res->{data} and scalar @{ $res->{data} } ) {
     SWITCH: {
        if ( $cmd eq 'mod' ) {
          my $inf = shift @{ $res->{data} };
          $msg = join ' ', $inf->{mod_name}, $inf->{mod_vers}, $inf->{cpan_id}, $inf->{dist_file};
          last SWITCH;
        }
        if ( $cmd eq 'dist' ) {
          my $inf = shift @{ $res->{data} };
          $msg = join ' ', $inf->{dist_name}, $inf->{dist_vers}, $inf->{cpan_id}, $inf->{dist_file};
          last SWITCH;
        }
        if ( $cmd eq 'dists' ) {
          $msg = join ' ', lc $search, 'has', scalar @{ $res->{data} }, 'dist(s) on CPAN';
          last SWITCH;
        }
        if ( $cmd eq 'auth' ) {
          my $inf = shift @{ $res->{data} };
          $msg = join ' ', $inf->{cpan_id}, $inf->{fullname}, $inf->{email};
          last SWITCH;
        }
        if ( $cmd eq 'topten' ) {
          $msg = join ' ', map { ( $_->{cpan_id}, '['.$_->{dists}.']' ) } @{ $res->{data} };
          last SWITCH;
        }
     }
  }
  elsif ( $res->{data} and !scalar @{ $res->{data} } ) {
     $msg = 'No information for that';
  }
  else {
     $msg = 'blah. Something wicked happened.';
  }
  $irc->yield( 'privmsg', $channel, "$nick: $msg" );
  return;
}

sub _nntp_connect {
  $poe_kernel->post ( 'NNTP-Client' => 'connect' );
  return;
}

sub _disconnected {
  $poe_kernel->delay( _nntp_poll => undef );
  $poe_kernel->delay( _nntp_connect => 60 );
  undef;
}

sub nntp_200 {
  warn "NNTP_200\n";
  $poe_kernel->yield( '_nntp_poll' );
  undef;
}

sub _nntp_poll {
  warn "NNTP_POLL\n";
  $poe_kernel->post ( 'NNTP-Client' => group => $group );
}

sub nntp_211 {
  my ($kernel,$self) = @_[KERNEL,HEAP];
  my ($estimate,$first,$last,$group) = split( /\s+/, $_[ARG0] );
  warn "NNTP_211\n";

  if ( defined $self->{articles}->{ $group } ) {
	# Check for new articles
	if ( $estimate >= $self->{articles}->{ $group } ) {
	   for my $article ( $self->{articles}->{ $group } .. $estimate ) {
		$kernel->post ( 'NNTP-Client' => article => $article );
	   }
	   $self->{articles}->{ $group } = $estimate + 1;
	}
  } else {
	$self->{articles}->{ $group } = $estimate + 1;
  }
  $kernel->delay( '_nntp_poll' => ( $self->{poll} || 60 ) );
  undef;
}

sub nntp_220 {
  my ($kernel,$self,$text) = @_[KERNEL,HEAP,ARG0];
  warn "NNTP_220\n";

  my $mail = Email::Simple->new( join "\n", @{ $_[ARG1] } );
  return if $mail->header("In-Reply-To");
  my $subject = $mail->header("Subject");
  return unless $subject;
  if ( $subject =~ /^CPAN Upload: (.+)$/i ) {
	my $d = CPAN::DistnameInfo->new($1);
	my $author = $d->cpanid;
	my $module = $d->distvname;
	return unless $module;
	foreach my $channel ( keys %channels ) {
	   my $regexp = $channels{$channel};
	   eval { 
	      $irc->yield( 'ctcp', $channel, "ACTION CPAN Upload: $module by $author" ) if $module =~ /$regexp/;
	   }
	}
	return;
  }
  return;
}

# We registered for all events, this will produce some debug info.
sub _default {
   my ($event, $args) = @_[ARG0 .. $#_];
   my @output = ( "$event: " );

   for my $arg (@$args) {
      if ( ref $arg eq 'ARRAY' ) {
         push( @output, '[' . join(', ', @$arg ) . ']' );
      }
      else {
         push ( @output, "'$arg'" );
      }
   }
   print join ' ', @output, "\n";
   return 0;
}
