"""Add synchronized generation favorites and ratings.

Revision ID: 0005
Revises: 0004
"""
from alembic import op
import sqlalchemy as sa

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("generations", sa.Column("favorite", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column("generations", sa.Column("rating", sa.Integer(), nullable=True))
    op.create_check_constraint("ck_generations_rating_range", "generations", "rating IS NULL OR (rating >= 1 AND rating <= 5)")


def downgrade() -> None:
    op.drop_constraint("ck_generations_rating_range", "generations", type_="check")
    op.drop_column("generations", "rating")
    op.drop_column("generations", "favorite")
