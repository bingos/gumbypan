use strict;
use warnings;
use Email::Simple;
use POE qw(Component::IRC);
use POE::Component::IRC::Common qw( :ALL );
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::CTCP;
use POE::Component::IRC::Plugin::BotAddressed;
use POE::Component::Client::NNTP::Tail;
use POE::Component::CPANIDX;
use CPAN::DistnameInfo;
use Module::Util qw[is_valid_module_name];
use version;

use constant IDX => 'http://cpanidx.org/cpanidx/';

my $repository = 'https://github.com/bingos/gumbypan';

my $cmds = {
  'mod', 1,
  'dist' => 1,
  'auth', 1,
  'timestamp', 0,
  'dists', 1,
  'topten', 0,
  'corelist' => 1,
};

my $help = {
  'mod', 'Look up a module on CPAN',
  'dist' , 'Look up a distribution on CPAN',
  'auth', 'Look up a CPANID on CPAN',
  'timestamp', 'See when the CPANIDX was last updated',
  'dists', 'See how many dists a CPAN author has',
  'topten', 'See the CPAN topten',
  'corelist', 'Check if a CPAN module is included in Perl core',
  'source', 'A link to the GumbyPAN source code repository',
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

my $irc = POE::Component::IRC->spawn( debug => 0 );
my $idx = POE::Component::CPANIDX->spawn();

POE::Component::Client::NNTP::Tail->spawn(
   NNTPServer  => 'nntp.perl.org',
   Group       => 'perl.cpan.uploads',
);

POE::Component::Client::NNTP::Tail->spawn(
   NNTPServer  => 'nntp.perl.org',
   Group       => 'perl.modules',
);

POE::Session->create(
    package_states => [
	    'main' => [ qw(_start irc_001 irc_join irc_bot_addressed _default _idx _uploads _modules _article _help) ],
    ],
    options => { trace => 0 },
);

$poe_kernel->run();
exit 0;

sub _start {
  my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
  $kernel->post( 'perl.cpan.uploads', 'register', '_uploads' );
  $kernel->post( 'perl.modules', 'register', '_modules' );
  $irc->yield( register => 'all' );
  $irc->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new() );
  $irc->plugin_add( 'CTCP', POE::Component::IRC::Plugin::CTCP->new( eat => 0, source => $repository ) );
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
  if ( $cmd =~ /^(help|source)$/i ) {
    $kernel->yield( '_help', $nick, $channel, $cmd, $search );
    return;
  }
  return unless defined $cmds->{ $cmd };
  my $arg = $cmds->{ $cmd };
  return if $arg and !$search;
  return if $cmd =~ /^(mod|corelist)$/ and !is_valid_module_name($search);
  $idx->query_idx(
        event   => '_idx',
        cmd     => $cmd,
        search  => $search,
        url     => IDX,
        _data   => [ $channel, $nick, $cmd, $search ],
  );
  return;
}

sub _help {
  my ($kernel,$heap,$nick,$channel,$cmd,$search) = @_[KERNEL,HEAP,ARG0..$#_];
  if ( $cmd eq 'source' ) {
    $irc->yield( 'privmsg', $channel, "$nick: Source code -> $repository" );
    return;
  }
  if ( $search and my $help = $help->{ lc $search } ) {
    $irc->yield( 'privmsg', $channel, "$nick: $help" );
    return;
  }
  my $cmds = join ', ', sort keys %{ $help };
  $irc->yield( 'privmsg', $channel, "$nick: available commands [ " . $cmds . ' ]' );
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
        if ( $cmd eq 'corelist' ) {
          my $inf = shift @{ $res->{data} };
          $msg = join ' ', $search, 'was first released with perl', format_perl_version( $inf->{perl_ver} );
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

sub _uploads {
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
	      $irc->yield( 'ctcp', $channel, "ACTION CPAN Upload: $module by $author (http://metacpan.org/release/$author/$module)" ) if $module =~ /$regexp/;
	    }
	  }
	  return;
  }
  return;
}

sub _modules {
  my ($kernel,$id,$lines) = @_[KERNEL,ARG0,ARG1];
  my $article = Email::Simple->new( join("\r\n", @$lines) );
  return unless $article->header('Subject') =~ /^Welcome new user/i;
  $kernel->post( $_[SENDER], 'get_article', $id, '_article' );
  return;
}

sub _article {
  my ($kernel,$id,$lines) = @_[KERNEL,ARG0,ARG1];
  my $article = Email::Simple->new( join("\r\n", @$lines) );
  my ($author) = $article->body =~ /Welcome (.*?),/s;
  my ($cpanid) = $article->body =~ /has a userid for you:\s+(.*?)\s+/s;
	foreach my $channel ( keys %channels ) {
	    my $regexp = $channels{$channel};
	    eval {
	      $irc->yield( 'ctcp', $channel, "ACTION welcomes $cpanid - $author to CPAN!" );
	    }
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

sub format_perl_version {
    my $v = shift;
    return $v if $v < 5.006;
    return version->new($v)->normal;
}
