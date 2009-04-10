use strict;
use warnings;
use Email::Simple;
use POE qw(Component::IRC);
use POE::Component::IRC::Common qw( :ALL );
use POE::Component::IRC::Plugin::Connector;
use POE::Component::Client::NNTP;
use CPAN::DistnameInfo;

my $nickname = 'GumbyPAN';
my $username = 'cpanbot';
my $server = 'irc.freenode.net';
my $port = 6667;

my %channels = ( 
		'#perl' => '.*', 
		);

my $group = 'perl.cpan.uploads';

my $irc = POE::Component::IRC->spawn( debug => 0 );

POE::Component::Client::NNTP->spawn ( 'NNTP-Client', { NNTPServer => 'nntp.perl.org' } );

POE::Session->create(
    package_states => [ 
	'main' => [ qw(_start irc_001 irc_join _nntp_connect _nntp_poll nntp_200 nntp_211 nntp_220 _default) ], 
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
  $irc->yield( connect => { Nick => $nickname, Server => $server, Port => $port, Username => $username } );
  return;
}

sub irc_001 {
  $irc->yield( 'join', $_ ) for keys %channels;
  return;
}

sub irc_join {
  my ($nickhost,$channel) = @_[ARG0,ARG1];
  my $nick = parse_user( $nickhost );
  return unless $nick eq 'GumbyNET2';
  $irc->yield( 'part', $channel );
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
  $poe_kernel->yield( '_nntp_poll' );
  undef;
}

sub _nntp_poll {
  $poe_kernel->post ( 'NNTP-Client' => group => $group );
}

sub nntp_211 {
  my ($kernel,$self) = @_[KERNEL,HEAP];
  my ($estimate,$first,$last,$group) = split( /\s+/, $_[ARG0] );

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
