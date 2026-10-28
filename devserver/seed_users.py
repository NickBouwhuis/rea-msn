"""Create a few test accounts (password: 123456) with no contacts.

The upstream dummydata.py builds a random contact graph; tests want an empty,
predictable starting state so they can exercise contact adds themselves.
"""
from util import misc
from core.db import Base, User
from core.conn import Conn
import settings

from script.user import set_passwords

ACCOUNTS = [
	('alice@example.com', 'alice', 'Alice'),
	('bob@example.com', 'bob', 'Bob'),
	('carol@example.com', 'carol', 'Carol'),
]

def main() -> None:
	conn = Conn(settings.DB)
	Base.metadata.create_all(conn.engine)
	with conn.session() as sess:
		for email, username, name in ACCOUNTS:
			if sess.query(User).filter(User.email == email).one_or_none() is not None:
				continue
			user = User(
				uuid = misc.gen_uuid(), email = email, username = username, verified = True,
				name = name, friendly_name = name, message = '', groups = {}, settings = {},
			)
			set_passwords(user, '123456')
			sess.add(user)
	print('Seeded', len(ACCOUNTS), 'accounts')

if __name__ == '__main__':
	main()
